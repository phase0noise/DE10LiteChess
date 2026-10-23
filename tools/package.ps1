param([string]$Python = 'py')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & $Python tools/check_project.py
    if ($LASTEXITCODE -ne 0) { throw 'Self-contained project check failed.' }
    $artifacts = @('output_files/de10_chess.sof','output_files/de10_chess.pof','output_files/pico_chess.uf2')
    foreach ($name in $artifacts) {
        if (-not (Test-Path -LiteralPath $name)) { throw "Missing release artifact: $name" }
    }
    $files = @('README.md','.gitignore','.gitattributes','de10_chess.qpf','de10_chess.qsf','de10_chess.sdc')
    foreach ($folder in @('rtl','firmware','web','tools','sim','tests','docs')) {
        $files += Get-ChildItem -LiteralPath $folder -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/]__pycache__[\\/]|\.pyc$' } |
            ForEach-Object { $_.FullName.Substring($projectRoot.Length+1).Replace('\','/') }
    }
    $files += $artifacts
    $hashes = [ordered]@{}
    foreach ($name in ($files | Sort-Object -Unique)) {
        $hashes[$name] = (Get-FileHash -Algorithm SHA256 -LiteralPath $name).Hash.ToLowerInvariant()
    }
    $manifest = [ordered]@{
        target = 'DE10-Lite / 10M50DAF484C7G'
        bridge = 'Raspberry Pi Pico W / GP0 TX / GP1 RX / 115200 8N1'
        engine = [ordered]@{
            protocol = 4
            maxNormalDepth = 6
            defaultTargetDepth = 5
            defaultThinkSeconds = 10
            positionCacheEntries = 4096
        }
        ssid = 'FPGA-Chess'
        url = 'http://192.168.4.1/'
        ipConfiguration = 'Arduino-Pico library default, same as oscilloscope reference; USB serial prints the runtime address'
        physicalBoardAcceptance = 'Not performed; see docs/VALIDATION.md'
        sha256 = $hashes
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath output_files/build_manifest.json -Encoding UTF8
    $files += 'output_files/build_manifest.json'
    $stage = Join-Path $projectRoot ('.cache/release-' + [Guid]::NewGuid().ToString('N') + '/DE10LiteChess')
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($name in ($files | Sort-Object -Unique)) {
        $destination = Join-Path $stage $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $destination
    }
    & $Python tools/check_project.py $stage
    if ($LASTEXITCODE -ne 0) { throw 'Standalone staged package check failed.' }
    Compress-Archive -LiteralPath $stage -DestinationPath output_files/DE10LiteChess.zip -Force
    Write-Host "Portable project: $projectRoot/output_files/DE10LiteChess.zip"
} finally { Pop-Location }
