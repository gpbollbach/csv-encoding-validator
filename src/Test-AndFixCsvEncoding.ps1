<#
.SYNOPSIS
    CSV Encoding Validator & Converter – prüft CSV-Dateien auf ihre Zeichenkodierung
    und stellt sicher, dass sie in sauberem UTF-8 (ohne BOM) vorliegen.

.DESCRIPTION
    Verarbeitet sequenziell alle CSV-Dateien aus dem Eingabeverzeichnis:

      1. BOM-Analyse:      UTF-8-BOM (EF BB BF) wird erkannt und entfernt.
      2. UTF-8-Validierung: byteweise Prüfung auf valide UTF-8-Multibyte-Sequenzen
                            (Fall A: valides UTF-8, Fall B: invalides UTF-8,
                            meist Windows-1252/ISO-8859-1).
      3. Reparatur:         invalide Dateien werden mit Codepage 1252 gelesen und
                            als UTF-8 (ohne BOM) neu geschrieben.
      4. Integritätsprüfung: U+FFFD-Ersetzungszeichen, NUL-Bytes und Double-Encoding
                            (Mojibake wie 'Ã¤') führen nach /invalid.
      5. Logging & Exit-Codes: detailliertes Konsolen-Logging; Exit 0 = alle Dateien
                            valide/konvertiert, Exit 1 = unlösbare Fehler gefunden.

    Standardpfade sind auf die Docker-Volume-Mounts ausgelegt:
    /app/data/input, /app/data/output, /app/data/invalid.

.PARAMETER InputDir
    Verzeichnis mit den zu prüfenden CSV-Dateien. Default: /app/data/input.

.PARAMETER OutputDir
    Ziel für valide bzw. konvertierte UTF-8-Dateien. Default: /app/data/output.

.PARAMETER InvalidDir
    Quarantäne-Verzeichnis für irreparable/defekte Dateien. Default: /app/data/invalid.

.PARAMETER Move
    Wenn gesetzt, werden verarbeitete (valide/konvertierte) Dateien aus dem
    Eingabeverzeichnis verschoben statt kopiert. Defekte Dateien werden immer
    nach /invalid verschoben (Quarantäne), unabhängig von diesem Schalter.

.EXAMPLE
    pwsh -File src/Test-AndFixCsvEncoding.ps1

.EXAMPLE
    pwsh -File src/Test-AndFixCsvEncoding.ps1 -InputDir ./in -OutputDir ./out -InvalidDir ./invalid -Move
#>
[CmdletBinding()]
param(
    [string]$InputDir   = "/app/data/input",
    [string]$OutputDir  = "/app/data/output",
    [string]$InvalidDir = "/app/data/invalid",
    [switch]$Move
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function Write-Log {
    <#
    .SYNOPSIS
        Zeitgestempeltes Konsolen-Logging mit Level-Tag (INFO/OK/WARN/ERROR).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    switch ($Level) {
        "OK"    { $tag = " OK " }
        "WARN"  { $tag = "WARN" }
        "ERROR" { $tag = "ERR " }
        default { $tag = "INFO" }
    }
    Write-Host ("[{0}][{1}] {2}" -f $ts, $tag, $Message)
}

function Test-StrictUtf8Bytes {
    <#
    .SYNOPSIS
        Validiert ein Byte-Array byteweise gegen das UTF-8-Schema.

    .DESCRIPTION
        Prüft führende Bytes und Continuation-Bytes inkl. Ablehnung von
        Overlong-Encodings (z.B. 0xC0/0xC1), Surrogates (U+D800–U+DFFF) und
        Werten > U+10FFFF (0xF5–0xFF). Liefert $false, sobald eine Sequenz
        nicht dem Standard entspricht.
    #>
    param([byte[]]$Bytes)

    $i = 0
    $len = $Bytes.Length

    while ($i -lt $len) {
        $b = $Bytes[$i]

        # ASCII
        if ($b -lt 0x80) { $i++; continue }

        # 2 Byte: 0xC2-0xDF, Continuation 0x80-0xBF
        if ($b -ge 0xC2 -and $b -le 0xDF) {
            if ($i + 1 -ge $len) { return $false }
            $c1 = $Bytes[$i + 1]
            if ($c1 -lt 0x80 -or $c1 -gt 0xBF) { return $false }
            $i += 2
            continue
        }

        # 3 Byte: 0xE0 (2. Byte 0xA0-0xBF, Overlong-Schutz)
        if ($b -eq 0xE0) {
            if ($i + 2 -ge $len) { return $false }
            $c1 = $Bytes[$i + 1]; $c2 = $Bytes[$i + 2]
            if ($c1 -lt 0xA0 -or $c1 -gt 0xBF) { return $false }
            if ($c2 -lt 0x80 -or $c2 -gt 0xBF) { return $false }
            $i += 3
            continue
        }

        # 3 Byte: 0xE1-0xEC
        if ($b -ge 0xE1 -and $b -le 0xEC) {
            if ($i + 2 -ge $len) { return $false }
            $c1 = $Bytes[$i + 1]; $c2 = $Bytes[$i + 2]
            if ($c1 -lt 0x80 -or $c1 -gt 0xBF) { return $false }
            if ($c2 -lt 0x80 -or $c2 -gt 0xBF) { return $false }
            $i += 3
            continue
        }

        # 3 Byte: 0xED (2. Byte 0x80-0x9F, Surrogate-Schutz)
        if ($b -eq 0xED) {
            if ($i + 2 -ge $len) { return $false }
            $c1 = $Bytes[$i + 1]; $c2 = $Bytes[$i + 2]
            if ($c1 -lt 0x80 -or $c1 -gt 0x9F) { return $false }
            if ($c2 -lt 0x80 -or $c2 -gt 0xBF) { return $false }
            $i += 3
            continue
        }

        # 3 Byte: 0xEE-0xEF
        if ($b -ge 0xEE -and $b -le 0xEF) {
            if ($i + 2 -ge $len) { return $false }
            $c1 = $Bytes[$i + 1]; $c2 = $Bytes[$i + 2]
            if ($c1 -lt 0x80 -or $c1 -gt 0xBF) { return $false }
            if ($c2 -lt 0x80 -or $c2 -gt 0xBF) { return $false }
            $i += 3
            continue
        }

        # 4 Byte: 0xF0 (2. Byte 0x90-0xBF, Overlong-Schutz)
        if ($b -eq 0xF0) {
            if ($i + 3 -ge $len) { return $false }
            $c1 = $Bytes[$i + 1]; $c2 = $Bytes[$i + 2]; $c3 = $Bytes[$i + 3]
            if ($c1 -lt 0x90 -or $c1 -gt 0xBF) { return $false }
            if ($c2 -lt 0x80 -or $c2 -gt 0xBF) { return $false }
            if ($c3 -lt 0x80 -or $c3 -gt 0xBF) { return $false }
            $i += 4
            continue
        }

        # 4 Byte: 0xF1-0xF3
        if ($b -ge 0xF1 -and $b -le 0xF3) {
            if ($i + 3 -ge $len) { return $false }
            $c1 = $Bytes[$i + 1]; $c2 = $Bytes[$i + 2]; $c3 = $Bytes[$i + 3]
            if ($c1 -lt 0x80 -or $c1 -gt 0xBF) { return $false }
            if ($c2 -lt 0x80 -or $c2 -gt 0xBF) { return $false }
            if ($c3 -lt 0x80 -or $c3 -gt 0xBF) { return $false }
            $i += 4
            continue
        }

        # 4 Byte: 0xF4 (2. Byte 0x80-0x8F, Grenze U+10FFFF)
        if ($b -eq 0xF4) {
            if ($i + 3 -ge $len) { return $false }
            $c1 = $Bytes[$i + 1]; $c2 = $Bytes[$i + 2]; $c3 = $Bytes[$i + 3]
            if ($c1 -lt 0x80 -or $c1 -gt 0x8F) { return $false }
            if ($c2 -lt 0x80 -or $c2 -gt 0xBF) { return $false }
            if ($c3 -lt 0x80 -or $c3 -gt 0xBF) { return $false }
            $i += 4
            continue
        }

        # 0x80-0xC1 (nur Continuation/Overlong) oder 0xF5-0xFF: ungültiger Start
        return $false
    }

    return $true
}

# Muster für Double-Encoding/Mojibake: 'Ã'/'Â' gefolgt von Latin-1-Supplement
# (z.B. 'Ã¤' statt 'ä', 'Â°' statt '°'). U+FFFD und NUL werden separat geprüft.
$script:MojibakeRegex     = [regex]'[\u00C2\u00C3][\u0080-\u00BF]'
$script:ReplacementChar   = [string][char]0xFFFD
$script:NulChar           = [string][char]0x0000
$script:Cp1252            = [System.Text.Encoding]::GetEncoding(1252)
$script:Utf8Strict        = [System.Text.UTF8Encoding]::new($false, $true) # throwOnInvalidBytes
$script:Utf8NoBom         = [System.Text.UTF8Encoding]::new($false)

function Test-SaneText {
    <#
    .SYNOPSIS
        Integritätsprüfung des dekodierten Texts (Sanity Check).

    .DESCRIPTION
        Liefert $null, wenn der Text in Ordnung ist, andernfalls eine
        Begründung als String. Erkannt werden: U+FFFD-Ersetzungszeichen,
        NUL-Bytes (Hinweis auf UTF-16 ohne BOM) und Double-Encoding/Mojibake.
    #>
    param([string]$Text)

    if ($Text.Contains($script:ReplacementChar)) {
        return "U+FFFD (Ersetzungszeichen) gefunden – Inhalt ist beschädigt"
    }
    if ($Text.Contains($script:NulChar)) {
        return "NUL-Bytes (0x00) gefunden – vermutlich UTF-16 ohne BOM"
    }
    if ($script:MojibakeRegex.IsMatch($Text)) {
        return "Double-Encoding/Mojibake erkannt (z.B. 'Ã¤' statt 'ä')"
    }
    return $null
}

function ConvertTo-Utf8Text {
    <#
    .SYNOPSIS
        Dekodiert Bytes streng als UTF-8 (wirft bei invaliden Sequenzen).
    #>
    param([byte[]]$Bytes)
    return $script:Utf8Strict.GetString($Bytes)
}

function Write-Utf8NoBom {
    <#
    .SYNOPSIS
        Schreibt Text als UTF-8 ohne Byte-Order-Mark.
    #>
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

# ---------------------------------------------------------------------------
# Vorbereitung
# ---------------------------------------------------------------------------

Write-Log "=== CSV Encoding Validator & Converter ==="
Write-Log "Eingabeverzeichnis : $InputDir"
Write-Log "Ausgabeverzeichnis : $OutputDir"
Write-Log "Invalid-Verzeichnis: $InvalidDir"
if ($Move) { Write-Log "Modus: Dateien werden aus dem Eingabeverzeichnis verschoben (Move)." }

if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) {
    Write-Log "Eingabeverzeichnis '$InputDir' existiert nicht." -Level ERROR
    Write-Log "Abbruch (Exit-Code 1)." -Level ERROR
    exit 1
}

foreach ($dir in @($OutputDir, $InvalidDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Verzeichnis '$dir' wurde angelegt." -Level WARN
    }
}

$csvFiles = @(Get-ChildItem -LiteralPath $InputDir -File |
              Where-Object { $_.Extension -ieq ".csv" } |
              Sort-Object Name)

if ($csvFiles.Count -eq 0) {
    Write-Log "Keine CSV-Dateien im Eingabeverzeichnis gefunden – nichts zu tun."
    Write-Log "Fertig (Exit-Code 0)."
    exit 0
}

Write-Log "Gefundene CSV-Dateien: $($csvFiles.Count)"

# ---------------------------------------------------------------------------
# Hauptverarbeitung
# ---------------------------------------------------------------------------

$countValid   = 0   # valide, unverändert (byte-identisch kopiert/verschoben)
$countFixed   = 0   # BOM entfernt und/oder Windows-1252 -> UTF-8 konvertiert
$countInvalid = 0   # irreparabel -> Quarantäne /invalid
$countError   = 0   # technische Fehler (I/O, Dekodierung)

foreach ($file in $csvFiles) {
    $fileName    = $file.Name
    $destOutput  = Join-Path $OutputDir  $fileName
    $destInvalid = Join-Path $InvalidDir $fileName

    Write-Log ("--- [{0}] ---" -f $fileName)

    # --- Datei als Bytes einlesen ---
    try {
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    } catch {
        Write-Log "Datei konnte nicht gelesen werden: $($_.Exception.Message)" -Level ERROR
        $countError++
        continue
    }

    # --- Leere Datei: formal valides UTF-8 ---
    if ($bytes.Length -eq 0) {
        Write-Log "Datei ist leer – wird als valide behandelt." -Level OK
        Copy-Item -LiteralPath $file.FullName -Destination $destOutput -Force
        Write-Log "-> nach Output: $destOutput" -Level OK
        $countValid++
        continue
    }

    # --- 1) BOM-Analyse ---
    $hasUtf8Bom    = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $hasUtf16LeBom = $bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE
    $hasUtf16BeBom = $bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF
    $hasUtf32Bom   = $bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF

    $text          = $null        # dekodierter Text (wenn umgeschrieben werden muss)
    $needsRewrite  = $false       # $true => Text als UTF-8 ohne BOM neu schreiben
    $resultAction  = ""           # menschenlesbare Beschreibung des Ergebnisses

    if ($hasUtf8Bom) {
        Write-Log "UTF-8-BOM (EF BB BF) erkannt – BOM wird entfernt." -Level WARN

        if ($bytes.Length -eq 3) {
            $payload = [byte[]]::new(0)
        } else {
            $payload = [byte[]]$bytes[3..($bytes.Length - 1)]
        }

        if (Test-StrictUtf8Bytes $payload) {
            try { $text = ConvertTo-Utf8Text $payload } catch {
                Write-Log "UTF-8-Dekodierung unerwartet fehlgeschlagen: $($_.Exception.Message)" -Level ERROR
                $countError++
                continue
            }
            $resultAction = "BOM entfernt (Inhalt war valides UTF-8)"
        } else {
            # BOM + invalider Rest (selten): Repair des Rests als Windows-1252
            Write-Log "Inhalt hinter der BOM ist kein valides UTF-8 – Windows-1252-Repair." -Level WARN
            $text = $script:Cp1252.GetString($payload)
            $resultAction = "BOM entfernt + Windows-1252 -> UTF-8 konvertiert"
        }
        $needsRewrite = $true

    } elseif ($hasUtf16LeBom -or $hasUtf16BeBom -or $hasUtf32Bom) {
        Write-Log "UTF-16/UTF-32-BOM erkannt – diese Encodings werden nicht unterstützt." -Level WARN
        Move-Item -LiteralPath $file.FullName -Destination $destInvalid -Force
        Write-Log "-> irreparabel, nach Invalid verschoben: $destInvalid" -Level WARN
        $countInvalid++
        continue

    } elseif (Test-StrictUtf8Bytes $bytes) {
        # --- 2) Fall A: valides UTF-8 ohne BOM ---
        Write-Log "Valides UTF-8 ohne BOM erkannt – keine Konvertierung nötig." -Level OK
        try { $text = ConvertTo-Utf8Text $bytes } catch {
            Write-Log "UTF-8-Dekodierung unerwartet fehlgeschlagen: $($_.Exception.Message)" -Level ERROR
            $countError++
            continue
        }
        $resultAction = "valides UTF-8 (keine Änderung nötig)"

    } else {
        # --- 2) Fall B + 3) Repair: invalides UTF-8 (meist Windows-1252/ISO-8859-1) ---
        Write-Log "Kein valides UTF-8 – Windows-1252/ISO-8859-1 vermutet, Reparatur wird versucht." -Level WARN
        $text = $script:Cp1252.GetString($bytes)
        $resultAction = "Windows-1252 -> UTF-8 konvertiert"
        $needsRewrite = $true
    }

    # --- 4) Integritätsprüfung (Sanity Check) ---
    $sanityIssue = Test-SaneText $text
    if ($null -ne $sanityIssue) {
        Write-Log "Sanity-Check fehlgeschlagen: $sanityIssue" -Level ERROR
        Move-Item -LiteralPath $file.FullName -Destination $destInvalid -Force
        Write-Log "-> irreparabel, nach Invalid verschoben: $destInvalid" -Level WARN
        $countInvalid++
        continue
    }

    # --- Ausgabe: konvertieren oder byte-identisch übernehmen ---
    if ($needsRewrite) {
        Write-Utf8NoBom -Path $destOutput -Text $text
        if ($Move) {
            # Move-Modus: Original nach erfolgreicher Konvertierung entfernen
            Remove-Item -LiteralPath $file.FullName -Force
            Write-Log "-> $resultAction; als UTF-8 ohne BOM geschrieben: $destOutput (Original aus Eingabe entfernt, Move-Modus)" -Level OK
        } else {
            Write-Log "-> $resultAction; als UTF-8 ohne BOM geschrieben: $destOutput" -Level OK
        }
        $countFixed++
    } else {
        if ($Move) {
            Move-Item -LiteralPath $file.FullName -Destination $destOutput -Force
            Write-Log "-> $resultAction; nach Output verschoben: $destOutput" -Level OK
        } else {
            Copy-Item -LiteralPath $file.FullName -Destination $destOutput -Force
            Write-Log "-> $resultAction; nach Output kopiert: $destOutput" -Level OK
        }
        $countValid++
    }
}

# ---------------------------------------------------------------------------
# Zusammenfassung & Exit-Code
# ---------------------------------------------------------------------------

Write-Log "=== Zusammenfassung ==="
Write-Log "Dateien gesamt     : $($csvFiles.Count)"
Write-Log "Valide (kopiert)   : $countValid"
Write-Log "Konvertiert/gefixed: $countFixed"
Write-Log "Invalide (Invalid) : $countInvalid"
Write-Log "Technische Fehler  : $countError"

if ($countInvalid -gt 0 -or $countError -gt 0) {
    Write-Log "Exit-Code 1 – es wurden unlösbare Fehler gefunden." -Level ERROR
    exit 1
}

Write-Log "Exit-Code 0 – alle Dateien valide bzw. erfolgreich konvertiert." -Level OK
exit 0
