#requires -Version 5.1
# Native Windows runner for the upstream smolBSD microvm images.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'doctor', 'pull', 'kernfetch', 'images', 'run', 'bench')]
    [string]$Command = 'run',
    [Parameter(Position = 1)]
    [string]$Image = 'bsdshell-amd64:latest',
    [string]$DataDirectory,
    [string]$ImagePath,
    [string]$KernelPath,
    [string]$Qemu,
    [ValidateRange(64, 1048576)][int]$Memory = 256,
    [ValidateRange(1, 256)][int]$Cpus = 1,
    [string]$RootDisk,
    [string[]]$Forward = @(),
    [switch]$NoNetwork,
    [switch]$Snapshot,
    [switch]$Force,
    [switch]$DryRun,
    [ValidateRange(0, 65535)][int]$SerialPort = 0,
    [ValidateRange(1, 100)][int]$Runs = 1,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 30,
    [string]$ReadyPattern = 'bsd@shell\$\s*$'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Import-Module (Join-Path $PSScriptRoot 'windows/SmolBsd.psm1') -Force

try {
    if (!$DataDirectory) { $DataDirectory = Join-Path $PSScriptRoot 'data' }
    $identity = Get-SmolImageIdentity $Image
    $DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
    if (!$ImagePath) { $ImagePath = Join-Path $DataDirectory "images/$($identity.FileName)" }
    if (!$KernelPath) { $KernelPath = Join-Path $DataDirectory 'kernels/smolbsd' }
    if (!$RootDisk) { $RootDisk = "NAME=$($identity.Service)root" }

    switch ($Command) {
        'doctor' { Test-SmolHost -Qemu $Qemu }
        'pull' { Save-SmolImage -Identity $identity -Destination $ImagePath -Force:$Force }
        'kernfetch' { Save-SmolKernel -Destination $KernelPath -Force:$Force }
        'setup' {
            Test-SmolHost -Qemu $Qemu
            Save-SmolKernel -Destination $KernelPath -Force:$Force
            Save-SmolImage -Identity $identity -Destination $ImagePath -Force:$Force
        }
        'images' {
            $directory = Join-Path $DataDirectory 'images'
            if (Test-Path -LiteralPath $directory) {
                Get-ChildItem -LiteralPath $directory -Filter '*.img' |
                    Select-Object Name, Length, LastWriteTime
            }
        }
        'bench' {
            if ($SerialPort -or $DryRun) { throw 'bench manages its own serial connection; -SerialPort and -DryRun are not supported.' }
            $exe = Find-SmolQemu $Qemu
            Test-SmolHost -Qemu $exe
            $arguments = @(New-SmolQemuArguments -ImagePath $ImagePath -KernelPath $KernelPath `
                -Memory $Memory -Cpus $Cpus -RootDisk $RootDisk -Forward $Forward `
                -NoNetwork:$NoNetwork -Snapshot)
            $results = @(Measure-SmolBoot -Qemu $exe -Arguments $arguments -Runs $Runs `
                -TimeoutSeconds $TimeoutSeconds -ReadyPattern $ReadyPattern `
                -LogDirectory (Join-Path $DataDirectory 'bench'))
            $results
            $times = @($results.LaunchToUserspaceMs | Sort-Object)
            $middle = [int][Math]::Floor($times.Count / 2)
            $median = if ($times.Count % 2) { $times[$middle] } else { ($times[$middle - 1] + $times[$middle]) / 2 }
            Write-Host ('Launch to userspace: median {0:F1} ms, min {1:F1} ms, max {2:F1} ms ({3} run(s)).' -f `
                $median, $times[0], $times[-1], $times.Count)
            Write-Host 'Measured through a successful guest shell command; snapshot changes discarded. Network readiness is not measured.'
        }
        'run' {
            $exe = Find-SmolQemu $Qemu
            $arguments = New-SmolQemuArguments -ImagePath $ImagePath -KernelPath $KernelPath `
                -Memory $Memory -Cpus $Cpus -RootDisk $RootDisk -Forward $Forward `
                -NoNetwork:$NoNetwork -Snapshot:$Snapshot -SerialPort $SerialPort
            if ($DryRun) {
                [pscustomobject]@{ Executable = $exe; Arguments = @($arguments) }
                break
            }
            Test-SmolHost -Qemu $exe
            Write-Host "Starting $Image with WHPX ($Memory MiB, $Cpus CPU(s))."
            if (!$SerialPort) { Write-Host 'Console: Ctrl+A, then X exits QEMU. Guest disk writes persist unless -Snapshot is used.' }
            & $exe @arguments
            if ($LASTEXITCODE -ne 0) { throw "QEMU exited with code $LASTEXITCODE. See its diagnostic output above; no software fallback was used." }
        }
    }
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
