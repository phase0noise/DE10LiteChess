param([string]$ArduinoCli,[string]$Port,[string]$Uf2Drive)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($Port -and $Uf2Drive) { throw 'Choose either Port or Uf2Drive.' }
if (-not $ArduinoCli) {
    $cli = Get-Command arduino-cli -ErrorAction SilentlyContinue
    if ($cli) { $ArduinoCli = $cli.Source }
    else { $ArduinoCli = Join-Path $env:LOCALAPPDATA 'Programs/Arduino IDE/resources/app/lib/backend/resources/arduino-cli.exe' }
}
if (-not (Test-Path -LiteralPath $ArduinoCli)) { throw 'Arduino CLI not found. Pass -ArduinoCli.' }
Push-Location $projectRoot
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File web/embed_web.ps1
    if ($LASTEXITCODE -ne 0) { throw 'Embedding web assets failed.' }
    New-Item -ItemType Directory -Path output_files,.cache/pico -Force | Out-Null
    $board = 'rp2040:rp2040:rpipicow:freq=133'
    & $ArduinoCli compile --fqbn $board --build-path .cache/pico firmware/pico_chess
    if ($LASTEXITCODE -ne 0) { throw 'Pico W compilation failed.' }
    Copy-Item -LiteralPath .cache/pico/pico_chess.ino.uf2 -Destination output_files/pico_chess.uf2
    Write-Host "Pico W image: $projectRoot/output_files/pico_chess.uf2"
    if ($Port) {
        & $ArduinoCli upload --fqbn $board --port $Port --input-dir .cache/pico firmware/pico_chess
        if ($LASTEXITCODE -ne 0) { throw 'Upload failed. Use the Pico BOOTSEL drive instead.' }
    }
    if ($Uf2Drive) {
        $driveRoot = (Resolve-Path -LiteralPath $Uf2Drive).ProviderPath
        $info = Join-Path $driveRoot 'INFO_UF2.TXT'
        if (-not (Test-Path -LiteralPath $info) -or (Get-Content -LiteralPath $info -Raw) -notmatch '(?m)^Board-ID:\s*RPI-RP2\s*$') {
            throw 'Uf2Drive must be the RP2040 Pico W BOOTSEL drive.'
        }
        Copy-Item -LiteralPath output_files/pico_chess.uf2 -Destination (Join-Path $driveRoot 'pico_chess.uf2')
    }
} finally { Pop-Location }
