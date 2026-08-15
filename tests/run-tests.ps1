[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'src/Test-AndFixCsvEncoding.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ("csv-validator-tests-{0}" -f [Guid]::NewGuid().ToString('N'))
$inputDirectory = Join-Path $temp 'input'
$outputDirectory = Join-Path $temp 'output'
$invalidDirectory = Join-Path $temp 'invalid'
New-Item -ItemType Directory -Force -Path $inputDirectory, $outputDirectory, $invalidDirectory | Out-Null

function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Run-Validator {
    & pwsh -NoLogo -NoProfile -File $script -InputDirectory $inputDirectory -OutputDirectory $outputDirectory -InvalidDirectory $invalidDirectory | Out-Host
    return $LASTEXITCODE
}

try {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $utf8Bom = [Text.UTF8Encoding]::new($true)
    [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
    $cp1252 = [Text.Encoding]::GetEncoding(1252)
    [IO.File]::WriteAllText((Join-Path $inputDirectory 'utf8_valid.csv'), "Name;Wert`nMüller;Größe", $utf8)
    [IO.File]::WriteAllText((Join-Path $inputDirectory 'utf8_with_bom.csv'), "Name;Wert`nÄpfel;€", $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $inputDirectory 'ansi_windows1252.csv'), "Name;Wert`nJürgen;für 10 €", $cp1252)
    [IO.File]::WriteAllBytes((Join-Path $inputDirectory 'corrupted_encoding.csv'), [byte[]](0x4E,0x61,0x6D,0x65,0x3B,0xC3,0x28))

    $code = Run-Validator
    Assert ($code -eq 1) 'mixed run must report the irreparable input'
    Assert (Test-Path (Join-Path $outputDirectory 'utf8_valid.csv')) 'valid UTF-8 is missing'
    Assert (Test-Path (Join-Path $outputDirectory 'utf8_with_bom.csv')) 'BOM input is missing'
    Assert (Test-Path (Join-Path $outputDirectory 'ansi_windows1252.csv')) '1252 input is missing'
    Assert (Test-Path (Join-Path $invalidDirectory 'corrupted_encoding.csv')) 'corrupt input is not invalid'

    foreach ($name in 'utf8_valid.csv', 'utf8_with_bom.csv', 'ansi_windows1252.csv') {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $outputDirectory $name))
        Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "$name has BOM"
        $text = $utf8.GetString($bytes)
        Assert ($text -notmatch 'Ã|Â|�') "$name has encoding artifacts"
    }
    Assert ((Get-Content -Raw (Join-Path $outputDirectory 'ansi_windows1252.csv')) -match 'Jürgen;für 10 €') '1252 conversion text mismatch'
    Write-Output 'All tests passed.'
    exit 0
} finally {
    if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
