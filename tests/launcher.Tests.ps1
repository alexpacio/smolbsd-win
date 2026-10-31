# No Pester installation needed. Run with Windows PowerShell 5.1 or PowerShell 7.
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../windows/SmolBsd.psm1') -Force

function Assert($Condition, [string]$Message) {
    if (!$Condition) { throw "FAIL: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert $threw $Message
}

$temp = Join-Path ([IO.Path]::GetTempPath()) "smolbsd-tests-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $temp
try {
    $identity = Get-SmolImageIdentity 'bsdshell-amd64'
    Assert ($identity.Tag -eq 'latest') 'omitted tag defaults to latest'
    Assert ($identity.FileName -eq 'bsdshell-amd64_latest.img') 'colon must not become an NTFS stream'
    Assert ((Get-SmolImageIdentity 'test-service-amd64:v1.2').Service -eq 'test-service') 'service names may contain hyphens'
    foreach ($invalid in @('../shell-amd64', 'shell-arm64', 'shell-amd64:bad/tag', 'shell-amd64:', 'shell-amd64:foo:bar')) {
        Assert-Throws { Get-SmolImageIdentity $invalid } "reject unsafe image identity $invalid"
    }
    $disk = Join-Path $temp 'disk with spaces,and comma.img'
    $kernel = Join-Path $temp 'kernel with spaces'
    [IO.File]::WriteAllBytes($disk, [byte[]]@(1, 2, 3))
    [IO.File]::WriteAllBytes($kernel, [byte[]]@(4, 5, 6))
    $arguments = @(New-SmolQemuArguments -ImagePath $disk -KernelPath $kernel -Forward 'tcp:2222:22','udp:5353:53' -Snapshot)
    Assert ($arguments[$arguments.IndexOf('-accel') + 1] -eq 'whpx,hyperv=off') 'use WHPX without Hyper-V guest identification'
    Assert ($arguments[$arguments.IndexOf('-cpu') + 1] -eq 'kvm64-v1,+invtsc,vmware-cpuid-freq=off') 'use the compatible CPU and hypervisor identity'
    Assert ($arguments[$arguments.IndexOf('-kernel') + 1] -eq $kernel) 'keep spaced paths in one argument'
    Assert ($arguments[$arguments.IndexOf('-drive') + 1].Contains('spaces,,and comma.img')) 'escape QEMU option commas'
    Assert ($arguments -contains '-snapshot') 'snapshot is opt-in'
    $net = $arguments[$arguments.IndexOf('-netdev') + 1]
    Assert ($net.Contains('hostfwd=tcp:127.0.0.1:2222-:22')) 'TCP forward binds to loopback'
    Assert ($net.Contains('hostfwd=udp:127.0.0.1:5353-:53')) 'UDP forward binds to loopback'
    $offline = @(New-SmolQemuArguments -ImagePath $disk -KernelPath $kernel -NoNetwork -SerialPort 4444)
    Assert ($offline -notcontains '-netdev') 'offline mode removes the network backend'
    Assert ($offline -contains 'tcp:127.0.0.1:4444,server=on,wait=on') 'serial listener is local and waits for client'
    Assert ($offline -notcontains '-snapshot') 'normal guest writes persist'
    Assert-Throws { New-SmolQemuArguments -ImagePath $disk -KernelPath $kernel -NoNetwork -Forward 'tcp:22:22' } 'reject contradictory network options'
    Assert-Throws { New-SmolQemuArguments -ImagePath $disk -KernelPath $kernel -Forward 'tcp:65536:22' } 'reject out-of-range ports'
    Assert-Throws { New-SmolQemuArguments -ImagePath $disk -KernelPath $kernel -Forward 'tcp:22:22,hostfwd=tcp::80-:80' } 'reject injected network options'
    Assert-Throws { New-SmolQemuArguments -ImagePath $disk -KernelPath $kernel -RootDisk 'ld0a -s' } 'reject injected kernel options'
    Assert-Throws { New-SmolQemuArguments -ImagePath "$disk.missing" -KernelPath $kernel } 'missing image fails early'

    # Mock transport inside the module: exercise actual download verification and replacement.
    $module = Get-Module SmolBsd
    & $module {
        function script:Receive-SmolFile {
            param($Uri, $Headers, $Destination)
            [IO.File]::WriteAllBytes($Destination, [byte[]]@(7, 8, 9))
        }
    }
    $expected = Join-Path $temp 'expected'
    [IO.File]::WriteAllBytes($expected, [byte[]]@(7, 8, 9))
    $hash = (Get-FileHash $expected -Algorithm SHA256).Hash
    $original = (Get-FileHash $disk -Algorithm SHA256).Hash
    Assert-Throws { Save-SmolDownload -Uri 'https://invalid.example/blob' -Destination $disk -Sha256 ('0' * 64) -Size 3 } 'reject digest mismatch'
    Assert ((Get-FileHash $disk -Algorithm SHA256).Hash -eq $original) 'failed verification preserves existing disk'
    Assert-Throws { Save-SmolDownload -Uri 'https://invalid.example/blob' -Destination $disk -Sha256 $hash -Size 4 } 'reject truncated downloads'
    Save-SmolDownload -Uri 'https://invalid.example/blob' -Destination $disk -Sha256 $hash -Size 3
    Assert ((Get-FileHash $disk -Algorithm SHA256).Hash -eq $hash) 'verified download replaces destination'
    Assert (@(Get-ChildItem -LiteralPath $temp -Filter '*.part').Count -eq 0) 'partial downloads are removed'
    # PowerShell 5.1 resolves script parameter defaults differently under -File.
    $shell = (Get-Process -Id $PID).Path
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../smolbsd.ps1') images | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'CLI works through PowerShell -File with the default data directory'
    Write-Host 'PASS: identity, WHPX arguments, Windows paths, network options, and verified downloads.'
} finally {
    Remove-Module SmolBsd
    # Delete only the unique temporary directory created above, after resolving its boundary.
    $resolved = [IO.Path]::GetFullPath($temp)
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'smolbsd-tests-*') {
        throw "Refusing to remove unexpected test path: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
