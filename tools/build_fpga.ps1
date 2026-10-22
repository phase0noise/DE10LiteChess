param([string]$Quartus = 'C:/intelFPGA_lite/23.1std/quartus/bin64/quartus_sh.exe')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$mappedDrive = $null
$pushed = $false
try {
    # Same workaround as the scope example for Quartus below Documents.
    foreach ($letter in @('Q','R','S','T','U','V','W','X','Y','Z')) {
        $candidate = "${letter}:"
        if (-not (Test-Path "${candidate}\\")) {
            & subst.exe $candidate $projectRoot
            if ($LASTEXITCODE -eq 0) { $mappedDrive = $candidate; break }
        }
    }
    if (-not $mappedDrive) { throw 'No free drive letter for the Quartus build.' }
    Push-Location "${mappedDrive}\\"
    $pushed = $true
    & $Quartus --flow compile de10_chess
    if ($LASTEXITCODE -ne 0) { throw 'Quartus compilation failed.' }
    # Fail a release if any operating-condition setup/hold/recovery/removal
    # path misses timing; the Tcl script also rejects missing clock coverage.
    & (Join-Path (Split-Path $Quartus) 'quartus_sta.exe') -t tools/check_timing.tcl
    if ($LASTEXITCODE -ne 0) { throw 'Timing acceptance failed. Do not program this build.' }
    $report = Get-Content output_files/de10_chess.sta.rpt -Raw
    $coverage = [regex]::Matches($report, ';\s*(Illegal Clocks|Unconstrained Clocks|Unconstrained Input Ports|Unconstrained Output Ports)\s*;\s*(\d+)\s*;\s*(\d+)\s*;')
    if ($coverage.Count -ne 4) { throw 'Timing coverage summary is missing.' }
    foreach ($row in $coverage) {
        if ([int]$row.Groups[2].Value -ne 0 -or [int]$row.Groups[3].Value -ne 0) {
            throw "Incomplete timing coverage: $($row.Groups[1].Value)"
        }
    }
    Write-Host "FPGA image: $projectRoot/output_files/de10_chess.sof"
} finally {
    if ($pushed) { Pop-Location }
    if ($mappedDrive) { & subst.exe $mappedDrive /d | Out-Null }
}
