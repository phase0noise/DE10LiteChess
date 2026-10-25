param(
    [string]$Python = 'py',
    [string]$Node,
    [string]$Ghdl,
    [string]$Cxx,
    [int]$Positions = 128,
    [switch]$SkipSearch,
    [switch]$Strength,
    [switch]$Browser
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Node) {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCommand) { $Node = $nodeCommand.Source }
    elseif (Test-Path 'C:/Program Files/Microsoft VS Code/Code.exe') {
        $Node = 'C:/Program Files/Microsoft VS Code/Code.exe'
        $env:ELECTRON_RUN_AS_NODE = '1'
    } else { throw 'Node.js not found. Pass -Node.' }
}
if (-not $Ghdl) {
    $ghdlCommand = Get-Command ghdl -ErrorAction SilentlyContinue
    if ($ghdlCommand) { $Ghdl = $ghdlCommand.Source }
    else { $Ghdl = Join-Path $projectRoot '.cache/tools/ghdl/bin/ghdl.exe' }
}
if (-not $Cxx) {
    $cxxCommand = Get-Command g++ -ErrorAction SilentlyContinue
    if ($cxxCommand) { $Cxx = $cxxCommand.Source }
    else { $Cxx = 'C:/intelFPGA_lite/23.1std/questa_fse/gcc-7.4.0-mingw64vc16/bin/g++.exe' }
}
if (-not (Test-Path -LiteralPath $Ghdl)) { throw 'GHDL not found. Run tools/setup_test_tools.ps1 or pass -Ghdl.' }
if (-not (Test-Path -LiteralPath $Cxx)) { throw 'C++ compiler not found. Pass -Cxx.' }
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Path .cache/ghdl -Force | Out-Null
    if (Test-Path .cache/pydeps/chess/__init__.py) { $env:PYTHONPATH = Join-Path $projectRoot '.cache/pydeps' }
    & $Python tests/generate_fixtures.py --count $Positions
    if ($LASTEXITCODE -ne 0) { throw 'Independent fixture generation failed. Install python-chess.' }
    & $Node tests/rules.test.cjs .cache/rules.json | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Browser rules comparison failed.' }
    & $Node tests/fpga.test.cjs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Browser/FPGA verification failed.' }
    & $Cxx -std=c++11 -O2 -Wall -Wextra -o .cache/protocol_test.exe tests/protocol_test.cpp
    if ($LASTEXITCODE -ne 0) { throw 'Protocol test compile failed.' }
    & .cache/protocol_test.exe
    if ($LASTEXITCODE -ne 0) { throw 'Pico UART parser tests failed.' }
    $sources = @('rtl/chess_pkg.vhd','rtl/chess_cell_memory.vhd','rtl/chess_spatial.vhd',
                 'rtl/chess_search_memory.vhd','rtl/chess_see.vhd','rtl/chess_engine.vhd','rtl/chess_uart_bridge.vhd',
                 'sim/tb_chess_uart.vhd','sim/tb_chess_engine.vhd','sim/tb_chess_search_memory.vhd','sim/tb_chess_see.vhd',
                 'sim/tb_chess_arithmetic.vhd')
    & $Ghdl -a --std=08 --workdir=.cache/ghdl @sources
    if ($LASTEXITCODE -ne 0) { throw 'VHDL analysis failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl tb_chess_arithmetic --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Fixed-point arithmetic comparison failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl tb_chess_search_memory --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Search memory tests failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl tb_chess_see --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Capture exchange tests failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl tb_chess_uart --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'VHDL UART integration failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl tb_chess_engine '-gVECTOR_FILE=.cache/chess_vectors.txt' -gCLOCK_DIVIDE=4 --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'VHDL legal-set comparison failed.' }
    if (-not $SkipSearch) {
        & "$PSScriptRoot/verify_search.ps1" -Python $Python -Ghdl $Ghdl -Strength:$Strength
    }
    if ($Browser) {
        & $Node tests/browser_smoke.cjs | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Browser smoke test failed.' }
    }
    Write-Host 'PASS: FPGA chess port verification.'
} finally { Pop-Location }
