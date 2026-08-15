<#
.SYNOPSIS
    Automatisierte Test-Suite für Test-AndFixCsvEncoding.ps1.

.DESCRIPTION
    Führt das Validator-Skript in zwei Phasen gegen die Fixtures aus
    tests/testdata/ aus und prüft Byte-Ergebnisse, Encodings, Exit-Codes
    und die Verteilung der Dateien auf output/invalid.

    Phase 1: alle 4 Fixtures  -> Exit-Code 1 erwartet, corrupted_encoding.csv
             landet in /invalid, die 3 guten Dateien valide in /output.
    Phase 2: nur die 3 guten  -> Exit-Code 0 erwartet, alle in /output.

    Das Skript wird als Kindprozess (pwsh -File) gestartet, damit dessen
    `exit`-Code sauber über $LASTEXITCODE geprüft werden kann.

.PARAMETER ScriptPath
    Pfad zu Test-AndFixCsvEncoding.ps1 (Default: ../src/... relativ zu $PSScriptRoot).

.PARAMETER KeepTemp
    Temporäres Testverzeichnis nicht löschen (Debugging).

.EXAMPLE
    pwsh -NoProfile -File tests/run-tests.ps1

.EXAMPLE
    docker run --rm --entrypoint pwsh -v "$(pwd):/app" -w /app \
        csv-encoding-validator:latest -NoProfile -File /app/tests/run-tests.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../src/Test-AndFixCsvEncoding.ps1")),
    [string]$TestDataDir = (Join-Path $PSScriptRoot "testdata"),
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Erwarteter Inhalt der "guten" Fixtures (identisch in allen drei Dateien)
# ---------------------------------------------------------------------------
$expectedText = "Name;Stadt;Notiz`nMüller;München;Grüße`nStraße;Österreich;für ÄÖÜ äöü ß`n"

# ---------------------------------------------------------------------------
# Test-Rahmenwerk
# ---------------------------------------------------------------------------
$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:passed++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
    }
}

function Test-IsStrictUtf8 {
    param([string]$Path)
    try {
        $enc = [System.Text.UTF8Encoding]::new($false, $true)
        [void]$enc.GetString([System.IO.File]::ReadAllBytes($Path))
        return $true
    } catch { return $false }
}

function Test-NoUtf8Bom {
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 3) { return $true }
    return -not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

function Test-SameBytes {
    param([string]$PathA, [string]$PathB)
    $a = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($PathA))
    $b = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($PathB))
    return ($a -eq $b)
}

function Read-TextUtf8 {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Vorbereitung
# ---------------------------------------------------------------------------
Write-Host "=== CSV Encoding Validator – Test-Suite ==="
Write-Host "Skript: $ScriptPath"
Write-Host "Fixtures: $TestDataDir"

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Skript nicht gefunden: $ScriptPath"
}
foreach ($f in @("utf8_valid.csv", "utf8_with_bom.csv", "ansi_windows1252.csv", "corrupted_encoding.csv")) {
    if (-not (Test-Path -LiteralPath (Join-Path $TestDataDir $f) -PathType Leaf)) {
        throw "Fixture fehlt: $f (bitte tools/regen-testdata.py ausführen)"
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("csv-enc-tests-" + [guid]::NewGuid().ToString("N"))
$inDir  = Join-Path $testRoot "input"
$outDir = Join-Path $testRoot "output"
$invDir = Join-Path $testRoot "invalid"
New-Item -ItemType Directory -Force -Path $inDir, $outDir, $invDir | Out-Null

try {
    # -----------------------------------------------------------------------
    # Phase 1: alle 4 Fixtures -> Exit 1, corrupted nach invalid
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "--- Phase 1: alle 4 Fixtures (erwartet: Exit 1) ---"
    Copy-Item -Path (Join-Path $TestDataDir "*.csv") -Destination $inDir

    $phase1Log = & pwsh -NoProfile -File $ScriptPath -InputDir $inDir -OutputDir $outDir -InvalidDir $invDir 2>&1
    $exit1 = $LASTEXITCODE
    $phase1Log | ForEach-Object { Write-Host $_ }

    $p1outValid   = Join-Path $outDir "utf8_valid.csv"
    $p1outBom     = Join-Path $outDir "utf8_with_bom.csv"
    $p1outAnsi    = Join-Path $outDir "ansi_windows1252.csv"
    $p1outCorrupt = Join-Path $outDir "corrupted_encoding.csv"
    $p1invCorrupt = Join-Path $invDir "corrupted_encoding.csv"

    Assert-True ($exit1 -eq 1) "Phase 1: Exit-Code ist 1 (korrupte Datei vorhanden)"

    Assert-True (Test-Path -LiteralPath $p1outValid)  "Phase 1: utf8_valid.csv liegt in output"
    Assert-True (Test-Path -LiteralPath $p1outBom)    "Phase 1: utf8_with_bom.csv liegt in output"
    Assert-True (Test-Path -LiteralPath $p1outAnsi)   "Phase 1: ansi_windows1252.csv liegt in output"
    Assert-True (-not (Test-Path -LiteralPath $p1outCorrupt)) "Phase 1: corrupted_encoding.csv ist NICHT in output"
    Assert-True (Test-Path -LiteralPath $p1invCorrupt) "Phase 1: corrupted_encoding.csv liegt in invalid"

    Assert-True (Test-SameBytes $p1outValid (Join-Path $TestDataDir "utf8_valid.csv")) `
        "Phase 1: utf8_valid.csv wurde byte-identisch übernommen"
    Assert-True (Test-NoUtf8Bom $p1outValid) "Phase 1: utf8_valid.csv ohne BOM"

    Assert-True (Test-NoUtf8Bom $p1outBom) "Phase 1: utf8_with_bom.csv ohne BOM (BOM entfernt)"
    Assert-True (Test-IsStrictUtf8 $p1outBom) "Phase 1: utf8_with_bom.csv ist valides UTF-8"
    Assert-True ((Read-TextUtf8 $p1outBom) -eq $expectedText) "Phase 1: utf8_with_bom.csv Inhalt korrekt (Umlaute erhalten)"

    Assert-True (Test-NoUtf8Bom $p1outAnsi) "Phase 1: ansi_windows1252.csv ohne BOM"
    Assert-True (Test-IsStrictUtf8 $p1outAnsi) "Phase 1: ansi_windows1252.csv wurde zu valideem UTF-8 konvertiert"
    Assert-True ((Read-TextUtf8 $p1outAnsi) -eq $expectedText) "Phase 1: ansi_windows1252.csv Inhalt korrekt (äöüÄÖÜß erhalten)"

    # -----------------------------------------------------------------------
    # Phase 2: nur die 3 guten Fixtures -> Exit 0
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "--- Phase 2: nur valide/reparierbare Fixtures (erwartet: Exit 0) ---"
    $inDir2  = Join-Path $testRoot "input2"
    $outDir2 = Join-Path $testRoot "output2"
    $invDir2 = Join-Path $testRoot "invalid2"
    New-Item -ItemType Directory -Force -Path $inDir2, $outDir2, $invDir2 | Out-Null
    Copy-Item -LiteralPath (Join-Path $TestDataDir "utf8_valid.csv")    -Destination $inDir2
    Copy-Item -LiteralPath (Join-Path $TestDataDir "utf8_with_bom.csv") -Destination $inDir2
    Copy-Item -LiteralPath (Join-Path $TestDataDir "ansi_windows1252.csv") -Destination $inDir2

    $phase2Log = & pwsh -NoProfile -File $ScriptPath -InputDir $inDir2 -OutputDir $outDir2 -InvalidDir $invDir2 2>&1
    $exit2 = $LASTEXITCODE
    $phase2Log | ForEach-Object { Write-Host $_ }

    Assert-True ($exit2 -eq 0) "Phase 2: Exit-Code ist 0 (alle Dateien verarbeitbar)"
    Assert-True ((Get-ChildItem -LiteralPath $outDir2 -File).Count -eq 3) "Phase 2: 3 Dateien in output"
    Assert-True ((Get-ChildItem -LiteralPath $invDir2 -File).Count -eq 0) "Phase 2: invalid ist leer"
    Assert-True ((Get-ChildItem -LiteralPath $inDir2 -File).Count -eq 3) "Phase 2: Eingabedateien bleiben erhalten (Copy-Default)"

    # -----------------------------------------------------------------------
    # Phase 3: leere Datei (Edge Case) -> Exit 0
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "--- Phase 3: leere CSV-Datei (erwartet: Exit 0) ---"
    $inDir3  = Join-Path $testRoot "input3"
    $outDir3 = Join-Path $testRoot "output3"
    $invDir3 = Join-Path $testRoot "invalid3"
    New-Item -ItemType Directory -Force -Path $inDir3, $outDir3, $invDir3 | Out-Null
    New-Item -ItemType File -Path (Join-Path $inDir3 "leer.csv") -Force | Out-Null

    $phase3Log = & pwsh -NoProfile -File $ScriptPath -InputDir $inDir3 -OutputDir $outDir3 -InvalidDir $invDir3 2>&1
    $exit3 = $LASTEXITCODE
    $phase3Log | ForEach-Object { Write-Host $_ }

    Assert-True ($exit3 -eq 0) "Phase 3: Exit-Code ist 0 (leere Datei gilt als valide)"
    Assert-True (Test-Path -LiteralPath (Join-Path $outDir3 "leer.csv")) "Phase 3: leere Datei liegt in output"

    # -----------------------------------------------------------------------
    # Phase 4: Move-Modus -> Eingabeverzeichnis wird geleert
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "--- Phase 4: -Move Modus (erwartet: Exit 0, input wird geleert) ---"
    $inDir4  = Join-Path $testRoot "input4"
    $outDir4 = Join-Path $testRoot "output4"
    $invDir4 = Join-Path $testRoot "invalid4"
    New-Item -ItemType Directory -Force -Path $inDir4, $outDir4, $invDir4 | Out-Null
    Copy-Item -LiteralPath (Join-Path $TestDataDir "utf8_valid.csv") -Destination $inDir4
    Copy-Item -LiteralPath (Join-Path $TestDataDir "ansi_windows1252.csv") -Destination $inDir4

    $phase4Log = & pwsh -NoProfile -File $ScriptPath -InputDir $inDir4 -OutputDir $outDir4 -InvalidDir $invDir4 -Move 2>&1
    $exit4 = $LASTEXITCODE
    $phase4Log | ForEach-Object { Write-Host $_ }

    Assert-True ($exit4 -eq 0) "Phase 4: Exit-Code ist 0"
    Assert-True ((Get-ChildItem -LiteralPath $outDir4 -File).Count -eq 2) "Phase 4: 2 Dateien in output"
    Assert-True ((Get-ChildItem -LiteralPath $inDir4 -File).Count -eq 0) "Phase 4: Eingabeverzeichnis wurde geleert (Move)"

} finally {
    if (-not $KeepTemp) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Temporäre Testdaten behalten: $testRoot" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Ergebnis
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("Ergebnis: {0} bestanden, {1} fehlgeschlagen" -f $script:passed, $script:failed)
if ($script:failed -gt 0) {
    Write-Host "TEST-SUITE FEHLGESCHLAGEN" -ForegroundColor Red
    exit 1
}
Write-Host "TEST-SUITE BESTANDEN" -ForegroundColor Green
exit 0
