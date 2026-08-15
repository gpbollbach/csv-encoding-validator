[CmdletBinding()]
param(
    [string] $InputDirectory = '/app/data/input',
    [string] $OutputDirectory = '/app/data/output',
    [string] $InvalidDirectory = '/app/data/invalid'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string] $Level, [string] $Message)
    Write-Output ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Level, $Message)
}

function Test-ValidUtf8 {
    param([byte[]] $Bytes, [int] $Offset = 0)

    for ($index = $Offset; $index -lt $Bytes.Length; $index++) {
        $first = [int]$Bytes[$index]
        if ($first -le 0x7F) { continue }

        if ($first -ge 0xC2 -and $first -le 0xDF) {
            if ($index + 1 -ge $Bytes.Length -or $Bytes[$index + 1] -lt 0x80 -or $Bytes[$index + 1] -gt 0xBF) { return $false }
            $index++
            continue
        }

        if ($first -ge 0xE0 -and $first -le 0xEF) {
            if ($index + 2 -ge $Bytes.Length) { return $false }
            $second = [int]$Bytes[$index + 1]
            $third = [int]$Bytes[$index + 2]
            if (($first -eq 0xE0 -and ($second -lt 0xA0 -or $second -gt 0xBF)) -or
                ($first -eq 0xED -and ($second -lt 0x80 -or $second -gt 0x9F)) -or
                ($first -ne 0xE0 -and $first -ne 0xED -and ($second -lt 0x80 -or $second -gt 0xBF)) -or
                $third -lt 0x80 -or $third -gt 0xBF) { return $false }
            $index += 2
            continue
        }

        if ($first -ge 0xF0 -and $first -le 0xF4) {
            if ($index + 3 -ge $Bytes.Length) { return $false }
            $second = [int]$Bytes[$index + 1]
            $third = [int]$Bytes[$index + 2]
            $fourth = [int]$Bytes[$index + 3]
            if (($first -eq 0xF0 -and ($second -lt 0x90 -or $second -gt 0xBF)) -or
                ($first -eq 0xF4 -and ($second -lt 0x80 -or $second -gt 0x8F)) -or
                ($first -ne 0xF0 -and $first -ne 0xF4 -and ($second -lt 0x80 -or $second -gt 0xBF)) -or
                $third -lt 0x80 -or $third -gt 0xBF -or $fourth -lt 0x80 -or $fourth -gt 0xBF) { return $false }
            $index += 3
            continue
        }

        return $false
    }

    return $true
}

function Get-UniquePath {
    param([string] $Directory, [string] $Name)
    $candidate = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [IO.Path]::GetExtension($Name)
    $counter = 1
    do {
        $candidate = Join-Path $Directory ("{0}_{1}{2}" -f $base, $counter, $extension)
        $counter++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function Write-Utf8Atomically {
    param([string] $Path, [byte[]] $Bytes)
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        Move-Item -LiteralPath $temporary -Destination $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Test-SanityText {
    param([string] $Text)
    if ($Text.IndexOf([char]0xFFFD) -ge 0) { return $false }
    return $Text -notmatch '(?:\u00C3.|\u00C2.|\u00E2.|\u00F0.)'
}

$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
[Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
$windows1252 = [Text.Encoding]::GetEncoding(1252)
$hadErrors = $false

New-Item -ItemType Directory -Force -Path $InputDirectory, $OutputDirectory, $InvalidDirectory | Out-Null
$files = @(Get-ChildItem -LiteralPath $InputDirectory -File | Where-Object { $_.Extension -ieq '.csv' } | Sort-Object Name)
Write-Log 'INFO' ("Starting; files={0}" -f $files.Count)

foreach ($file in $files) {
    $outputPath = Get-UniquePath -Directory $OutputDirectory -Name $file.Name
    try {
        Write-Log 'INFO' ("Processing; file={0}" -f $file.Name)
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $offset = 0
        $encodingKind = 'UTF-8'
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $offset = 3
            Write-Log 'INFO' 'Detected UTF-8 BOM; removing it.'
        } elseif (($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) -or
                  ($bytes.Length -ge 4 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) -or ($bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF)))) {
            throw 'UTF-16/UTF-32 BOM is not supported safely.'
        } elseif (-not (Test-ValidUtf8 -Bytes $bytes)) {
            $encodingKind = 'Windows-1252'
            Write-Log 'INFO' 'Invalid UTF-8 detected; decoding as Windows-1252.'
        }

        if ($encodingKind -eq 'UTF-8') {
            if ($offset -eq 0) {
                $contentBytes = $bytes
            } elseif ($offset -lt $bytes.Length) {
                $contentBytes = $bytes[$offset..($bytes.Length - 1)]
            } else {
                $contentBytes = [byte[]]::new(0)
            }
            $text = $utf8Strict.GetString($contentBytes)
        } else {
            $text = $windows1252.GetString($bytes)
            $contentBytes = $utf8Strict.GetBytes($text)
        }

        if (-not (Test-SanityText -Text $text)) { throw 'Sanity check failed: replacement or double-encoded characters found.' }
        Write-Utf8Atomically -Path $outputPath -Bytes $contentBytes
        $roundTrip = $utf8Strict.GetString([IO.File]::ReadAllBytes($outputPath))
        if (-not (Test-SanityText -Text $roundTrip)) { throw 'Output sanity check failed.' }
        Write-Log 'INFO' ("Success; file={0}; encoding={1}; output={2}" -f $file.Name, $encodingKind, [IO.Path]::GetFileName($outputPath))
    } catch {
        $hadErrors = $true
        if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
        $invalidPath = Get-UniquePath -Directory $InvalidDirectory -Name $file.Name
        Move-Item -LiteralPath $file.FullName -Destination $invalidPath
        Write-Log 'ERROR' ("Invalid; file={0}; reason={1}; movedTo={2}" -f $file.Name, $_.Exception.Message, [IO.Path]::GetFileName($invalidPath))
    }
}

if ($hadErrors) { exit 1 }
exit 0
