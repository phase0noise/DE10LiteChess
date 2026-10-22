param([string]$Python = 'py')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Path .cache/tools,.cache/pydeps -Force | Out-Null
    # Portable development dependencies stay in this project, not the system.
    & $Python -m pip install --disable-pip-version-check --target .cache/pydeps python-chess==1.999
    if ($LASTEXITCODE -ne 0) { throw 'Installing the independent rules oracle failed.' }
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri 'https://api.github.com/repos/ghdl/ghdl/releases/latest' -OutFile .cache/tools/ghdl-release.json -UseBasicParsing
    $release = Get-Content .cache/tools/ghdl-release.json -Raw | ConvertFrom-Json
    $asset = $release.assets | Where-Object { $_.name -match 'mcode.*(mingw64|ucrt64).*\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'No Windows x64 mcode release was found.' }
    $zip = Join-Path $projectRoot '.cache/tools/ghdl.zip'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath .cache/tools/ghdl -Force
    Write-Host "Portable simulator: $($release.tag_name), $($asset.name)"
} finally { Pop-Location }
