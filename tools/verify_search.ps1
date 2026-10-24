param(
    [string]$Python = 'py',
    [string]$Ghdl,
    [switch]$Strength
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Ghdl) { $Ghdl = Join-Path $projectRoot '.cache/tools/ghdl/bin/ghdl.exe' }
Push-Location $projectRoot
try {
    if (Test-Path .cache/pydeps/chess/__init__.py) { $env:PYTHONPATH = Join-Path $projectRoot '.cache/pydeps' }
    New-Item -ItemType Directory .cache/ghdl-search -Force | Out-Null
    if (-not (Test-Path .cache/chess_vectors.txt)) {
        & $Python tests/generate_fixtures.py --count 128
        if ($LASTEXITCODE -ne 0) { throw 'Independent rule fixtures failed.' }
    }
    & $Python tests/generate_search.py
    if ($LASTEXITCODE -ne 0) { throw 'Tactical fixtures failed.' }
    $sources = @('rtl/chess_pkg.vhd','rtl/chess_cell_memory.vhd','rtl/chess_spatial.vhd',
        'sim/chess_spatial_fast.vhd','rtl/chess_search_memory.vhd','rtl/chess_engine.vhd',
        'sim/tb_chess_engine.vhd','sim/tb_chess_spatial.vhd')
    & $Ghdl -a --std=08 --workdir=.cache/ghdl-search @sources
    if ($LASTEXITCODE -ne 0) { throw 'Search model analysis failed.' }
    # This model only accelerates simulation. Compare every source square with
    # the production wired attack fabric before using it for long searches.
    & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_spatial --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Spatial model equivalence failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=.cache/search_vectors.txt' -gSEARCH_DEPTH=3 -gCLOCK_DIVIDE=4 --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Existing tactical regression failed.' }
    $tactics = Get-Content .cache/search_vectors.txt
    @($tactics[4], $tactics[8]) | Set-Content .cache/cache_vectors.txt
    foreach ($cache in @(1,0)) {
        $log = ".cache/cache-$cache.log"
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=.cache/cache_vectors.txt' -gSEARCH_DEPTH=3 -gCLOCK_DIVIDE=4 -gDETERMINISTIC=true "-gCACHE_ENABLE=$cache" --assert-level=error *> $log
        if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 20; throw 'Cache regression failed.' }
    }
    & $Python tests/check_cache.py .cache/cache-1.log .cache/cache-0.log
    if ($LASTEXITCODE -ne 0) { throw 'Cache comparison failed.' }
    foreach ($fast in @('true','false')) {
        $log = ".cache/destinations-$fast.log"
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=.cache/cache_vectors.txt' -gSEARCH_DEPTH=3 -gCLOCK_DIVIDE=4 -gDETERMINISTIC=true "-gFAST_DESTINATIONS=$fast" --assert-level=error *> $log
        if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 20; throw 'Destination scan regression failed.' }
    }
    & $Python tests/check_destinations.py .cache/destinations-true.log .cache/destinations-false.log
    if ($LASTEXITCODE -ne 0) { throw 'Destination scan comparison failed.' }
    $tactics[8] | Set-Content .cache/budget_vectors.txt
    foreach ($budgetClock in @(10000,400000)) {
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=.cache/budget_vectors.txt' -gSEARCH_DEPTH=6 -gCLOCK_DIVIDE=4 -gBUDGET_SECONDS=1 "-gTEST_CLOCK_HZ=$budgetClock" -gEXPECT_TIMEOUT=true --assert-level=error
        if ($LASTEXITCODE -ne 0) { throw 'Completed-iteration budget/commit regression failed.' }
    }
    & $Python tests/generate_depth.py
    if ($LASTEXITCODE -ne 0) { throw 'Depth boundary fixtures failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=.cache/depth_vectors.txt' -gSEARCH_DEPTH=6 -gCLOCK_DIVIDE=4 --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Depth-six/insufficient-material regression failed.' }
    if ($Strength) {
        & $Python tests/generate_strength.py
        if ($LASTEXITCODE -ne 0) { throw 'Independent mate proofs failed.' }
        # Quiet KQ endings require five normal plies. Disable capture extensions
        # here so this benchmark specifically exercises deeper normal search.
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=.cache/strength_vectors.txt' -gSEARCH_DEPTH=5 -gQUIESCENCE=0 -gCLOCK_DIVIDE=4 --assert-level=error *> .cache/strength-expanded.log
        if ($LASTEXITCODE -ne 0) { Get-Content .cache/strength-expanded.log -Tail 20; throw 'Five-ply strength regression failed.' }
        & $Python tests/check_strength.py .cache/strength-expanded.log
        if ($LASTEXITCODE -ne 0) { throw 'Independent mate choice check failed.' }
    }
    Write-Host 'PASS: expanded search verification.'
} finally { Pop-Location }
