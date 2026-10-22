param(
    [string]$QuartusBin = 'C:/intelFPGA_lite/23.1std/quartus/bin64',
    [string]$Cable = 'USB-Blaster',
    [int]$DeviceIndex = 1
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$image = Join-Path $projectRoot 'output_files/de10_chess.sof'
if (-not (Test-Path -LiteralPath $image)) { throw 'Build the FPGA image first.' }
if ($DeviceIndex -lt 1) { throw 'DeviceIndex must be positive.' }
& (Join-Path $QuartusBin 'quartus_pgm.exe') -m jtag -c $Cable -o "p;$image@$DeviceIndex"
if ($LASTEXITCODE -ne 0) { throw 'Programming failed. Check the DE10-Lite cable and selected JTAG device.' }
Write-Host 'DE10-Lite configured in volatile SRAM. Reload the SOF after power cycling.'
