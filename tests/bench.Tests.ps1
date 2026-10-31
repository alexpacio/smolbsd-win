#requires -Version 5.1
# Integration checks: requires setup assets and a working WHPX host.
param([string]$ImagePath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
if (!$ImagePath) { $ImagePath = Join-Path $root 'data/images/bsdshell-amd64_latest.img' }
$launch = & (Join-Path $root 'smolbsd.ps1') run -ImagePath $ImagePath -DryRun
Import-Module (Join-Path $root 'windows/SmolBsd.psm1') -Force
$logs = Join-Path $root 'data/bench-tests'
$null = New-Item -ItemType Directory -Force -Path $logs
$before = @(Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | ForEach-Object Id)
function Assert($Condition, [string]$Message) {
    if (!$Condition) { throw "FAIL: $Message" }
}

# Exercise ProcessStartInfo quoting through a real boot, with a space/comma path.
$arguments = @($launch.Arguments)
$kernelIndex = [Array]::IndexOf($arguments, '-kernel') + 1
$testKernel = Join-Path $logs 'kernel with spaces, and comma'
Copy-Item -LiteralPath $arguments[$kernelIndex] -Destination $testKernel -Force
$arguments[$kernelIndex] = $testKernel
$hashBefore = (Get-FileHash -LiteralPath $ImagePath).Hash
$results = @(Measure-SmolBoot -Qemu $launch.Executable -Arguments $arguments -Runs 2 -LogDirectory $logs)
Assert ($results.Count -eq 2) 'one measurement per boot'
foreach ($result in $results) {
    Assert ($result.LaunchToUserspaceMs -ge $result.LaunchToShellMs) 'command confirmation follows prompt detection'
    Assert ($result.LaunchToShellMs -gt 0) 'positive host monotonic timing'
    Assert ($result.GuestKernelMs -gt 0) 'separate guest kernel timing captured'
    $serial = Get-Content -LiteralPath $result.SerialLog -Raw
    Assert ($serial -match '(?m)^SMOLBSD_BENCH_[a-f0-9]+\r*$') 'success requires an executed command, not its echo'
}

$failure = ''
try {
    Measure-SmolBoot -Qemu $launch.Executable -Arguments $arguments -TimeoutSeconds 1 `
        -ReadyPattern '^NEVER_MATCH_THIS_PROMPT$' -LogDirectory $logs | Out-Null
} catch { $failure = $_.Exception.Message }
Assert ($failure -like '*Timed out*') 'missing prompt times out instead of reporting a boot time'

$badKernel = Join-Path $logs 'invalid-kernel'
[IO.File]::WriteAllText($badKernel, 'Not a bootable kernel')
$arguments[$kernelIndex] = $badKernel
$failure = ''
try {
    Measure-SmolBoot -Qemu $launch.Executable -Arguments $arguments -LogDirectory $logs | Out-Null
} catch { $failure = $_.Exception.Message }
Assert ($failure -like '*QEMU exited*' -or $failure -like '*connection closed*') 'early QEMU exit fails with diagnostics'
$after = @(Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })
Assert ($after.Count -eq 0) 'success and failure paths leave no new QEMU processes'
Assert ((Get-FileHash -LiteralPath $ImagePath).Hash -eq $hashBefore) 'benchmark snapshot preserves guest image'
Write-Host 'PASS: measured boots, native argument quoting, command proof, timeout, early exit, process cleanup, and disk preservation.'
