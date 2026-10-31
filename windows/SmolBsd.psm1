#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SmolImageIdentity {
    param([Parameter(Mandatory)][string]$Image)
    # Deliberately accept one public amd64 artifact, not arbitrary paths or registry URLs.
    if ($Image -cnotmatch '^(?<service>[a-z0-9]+(?:[._-][a-z0-9]+)*)-amd64(?::(?<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}))?$') {
        throw "Invalid image '$Image'. Expected service-amd64[:tag], for example bsdshell-amd64:latest."
    }
    $service = $Matches.service
    $tag = if ($Matches.ContainsKey('tag')) { $Matches.tag } else { 'latest' }
    [pscustomobject]@{
        Service = $service
        Tag = $tag
        Repository = "netbsdfr/smolbsd/$service-amd64"
        FileName = "$service-amd64`_$tag.img"
    }
}

function Receive-SmolFile {
    param([string]$Uri, [string]$Destination, [hashtable]$Headers)
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $response = $null
    $file = $null
    try {
        foreach ($key in $Headers.Keys) { $client.DefaultRequestHeaders.Add($key, $Headers[$key]) }
        # Stream in .NET, avoiding PowerShell 5.1's slow large-file web cmdlet path.
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $null = $response.EnsureSuccessStatusCode()
        $file = [IO.File]::Create($Destination)
        if (!$response.Content.CopyToAsync($file).Wait([TimeSpan]::FromMinutes(10))) {
            throw 'Download timed out.'
        }
    } finally {
        if ($file) { $file.Dispose() }
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
}

function Save-SmolDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Sha256,
        [long]$Size = -1,
        [hashtable]$Headers = @{}
    )
    if ($Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid SHA256 digest.' }
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destinationPath))
    $temporary = "$destinationPath.$([Guid]::NewGuid().ToString('N')).part"
    try {
        # Never derive local paths from remote OCI annotations (which can contain ':' or traversal).
        Receive-SmolFile -Uri $Uri -Headers $Headers -Destination $temporary
        $actualSize = (Get-Item -LiteralPath $temporary).Length
        if ($actualSize -eq 0 -or ($Size -ge 0 -and $actualSize -ne $Size)) {
            throw "Download size mismatch for $Destination (received $actualSize, expected $Size)."
        }
        if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $Sha256) {
            throw "SHA256 mismatch for $Destination. The existing file has been preserved."
        }
        Move-Item -LiteralPath $temporary -Destination $destinationPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Save-SmolImage {
    param([Parameter(Mandatory)]$Identity, [Parameter(Mandatory)][string]$Destination, [switch]$Force)
    if ((Test-Path -LiteralPath $Destination) -and !$Force) {
        if ((Get-Item -LiteralPath $Destination).Length -eq 0) { throw "Empty image at $Destination. Use pull -Force to replace it." }
        Write-Host "Keeping $Destination (use -Force to replace, discarding guest changes)."
        return
    }
    $repository = $Identity.Repository
    $scope = [Uri]::EscapeDataString("repository:${repository}:pull")
    $token = (Invoke-RestMethod -TimeoutSec 60 -Uri "https://ghcr.io/token?service=ghcr.io&scope=$scope").token
    $headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.oci.image.manifest.v1+json' }
    $manifest = Invoke-RestMethod -TimeoutSec 60 -Uri "https://ghcr.io/v2/$repository/manifests/$($Identity.Tag)" -Headers $headers
    if ($manifest.mediaType -ne 'application/vnd.oci.image.manifest.v1+json') {
        throw 'Expected a single smolBSD OCI artifact manifest; image indexes are not supported.'
    }
    $layers = @($manifest.layers | Where-Object { $_.mediaType -eq 'application/x-raw-disk-image' })
    if ($layers.Count -ne 1 -or $layers[0].digest -notmatch '^sha256:([a-f0-9]{64})$') {
        throw 'Expected exactly one raw disk image layer with a SHA256 digest.'
    }
    $hash = $Matches[1]
    $layer = $layers[0]
    Write-Host "Fetching $repository`:$($Identity.Tag) -> $Destination"
    Save-SmolDownload -Uri "https://ghcr.io/v2/$repository/blobs/$($layer.digest)" `
        -Destination $Destination -Sha256 $hash -Size $layer.size -Headers @{ Authorization = "Bearer $token" }
    Write-Host "Verified image SHA256: $hash"
}

function Save-SmolKernel {
    param([Parameter(Mandatory)][string]$Destination, [switch]$Force)
    if ((Test-Path -LiteralPath $Destination) -and !$Force) {
        if ((Get-Item -LiteralPath $Destination).Length -eq 0) { throw "Empty kernel at $Destination. Use kernfetch -Force to replace it." }
        Write-Host "Keeping $Destination (use -Force to update)."
        return
    }
    # Same current asset location as the pinned upstream Makefile's kernfetch target.
    $uri = 'https://smolbsd.org/assets/amd64/smolbsd'
    $checksum = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$uri.sha256").Content
    if ($checksum -is [byte[]]) { $checksum = [Text.Encoding]::UTF8.GetString($checksum) }
    if ($checksum -notmatch '(?im)^SHA256 \(smolbsd\) = ([a-f0-9]{64})\s*$') {
        throw 'Unrecognized kernel checksum response.'
    }
    Write-Host "Fetching $uri -> $Destination"
    Save-SmolDownload -Uri $uri -Destination $Destination -Sha256 $Matches[1]
    Write-Host 'Verified kernel SHA256.'
}

function Find-SmolQemu {
    param([string]$Qemu)
    if ($Qemu) {
        $candidate = Get-Command $Qemu -CommandType Application -ErrorAction SilentlyContinue
        if (!$candidate) { throw "QEMU executable not found: $Qemu" }
        return $candidate.Source
    }
    $candidate = Get-Command 'qemu-system-x86_64.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.Source }
    if ($env:ProgramFiles) {
        $installed = Join-Path $env:ProgramFiles 'qemu/qemu-system-x86_64.exe'
        if (Test-Path -LiteralPath $installed) { return $installed }
    }
    throw 'Install QEMU for Windows with WHPX support, add it to PATH, or pass -Qemu C:\path\qemu-system-x86_64.exe.'
}

function Test-SmolHost {
    param([string]$Qemu)
    if ($env:OS -ne 'Windows_NT') { throw 'This launcher requires a Windows host.' }
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
        throw 'This launcher requires an x64 Windows host for the amd64 guest.'
    }
    $exe = Find-SmolQemu $Qemu
    $version = & $exe --version
    if ($LASTEXITCODE -ne 0) { throw 'Unable to query QEMU version.' }
    $accelerators = & $exe -accel help
    if ($LASTEXITCODE -ne 0 -or $accelerators -notcontains 'whpx') { throw 'This QEMU build does not support WHPX.' }
    if (!(Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32/WinHvPlatform.dll'))) {
        throw 'Enable Windows Hypervisor Platform (HypervisorPlatform) in Windows Features and reboot.'
    }
    if (!(Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
        throw 'The Windows hypervisor is not running. Enable firmware virtualization and Windows Hypervisor Platform, then reboot.'
    }
    Write-Host $version[0]
    Write-Host 'WHPX prerequisites detected. A guest boot is the operational check.'
}

function New-SmolQemuArguments {
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][string]$KernelPath,
        [int]$Memory = 256,
        [int]$Cpus = 1,
        [string]$RootDisk = 'NAME=bsdshellroot',
        [string[]]$Forward = @(),
        [switch]$NoNetwork,
        [switch]$Snapshot,
        [int]$SerialPort = 0
    )
    foreach ($file in @($ImagePath, $KernelPath)) {
        if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
            throw "Missing or empty asset: $file. Run .\smolbsd.ps1 setup first, or supply -ImagePath and -KernelPath."
        }
    }
    if ($RootDisk -notmatch '^[A-Za-z0-9_=./-]+$') { throw 'RootDisk must be a single NetBSD root device (e.g. NAME=bsdshellroot or ld0a).' }
    if ($NoNetwork -and $Forward.Count) { throw '-Forward cannot be combined with -NoNetwork.' }
    # QEMU's comma-separated option syntax escapes literal commas by doubling them.
    $disk = [IO.Path]::GetFullPath($ImagePath).Replace(',', ',,')
    $kernel = [IO.Path]::GetFullPath($KernelPath)
    $result = @(
        '-accel', 'whpx,hyperv=off',
        '-machine', 'microvm,rtc=on,acpi=off,pic=off',
        # Newer WHPX reports VMware CPUID by default. NetBSD only attaches its
        # pv bus for selected hypervisor IDs; disabling this restores KVM identity.
        '-cpu', 'kvm64-v1,+invtsc,vmware-cpuid-freq=off',
        '-smp', "$Cpus", '-m', "$Memory",
        '-kernel', $kernel,
        '-drive', "if=none,file=$disk,format=raw,id=rootdisk",
        '-device', 'virtio-blk-device,drive=rootdisk',
        '-append', "console=com root=$RootDisk -z",
        '-global', 'virtio-mmio.force-legacy=false',
        '-display', 'none',
        '-rtc', 'base=utc,clock=host,driftfix=slew',
        '-no-reboot'
    )
    if ($NoNetwork) {
        $result += @('-nic', 'none')
    } else {
        $net = 'user,id=net0,ipv6=off'
        foreach ($mapping in $Forward) {
            if ($mapping -notmatch '^(tcp|udp):([0-9]{1,5}):([0-9]{1,5})$') {
                throw "Invalid forward '$mapping'; use tcp:2222:22 or udp:5353:53 (bound to localhost)."
            }
            $protocol, $hostPort, $guestPort = $Matches[1], [int]$Matches[2], [int]$Matches[3]
            if ($hostPort -lt 1 -or $hostPort -gt 65535 -or $guestPort -lt 1 -or $guestPort -gt 65535) {
                throw "Port out of range in '$mapping'."
            }
            $net += ",hostfwd=${protocol}:127.0.0.1:${hostPort}-:${guestPort}"
        }
        $result += @('-netdev', $net, '-device', 'virtio-net-device,netdev=net0')
    }
    if ($SerialPort) {
        $result += @('-serial', "tcp:127.0.0.1:${SerialPort},server=on,wait=on", '-monitor', 'none')
    } else {
        $result += @('-serial', 'mon:stdio')
    }
    if ($Snapshot) { $result += '-snapshot' }
    $result
}

function ConvertTo-SmolNativeArgument {
    param([AllowEmptyString()][string]$Value)
    # ProcessStartInfo.ArgumentList is unavailable on Windows PowerShell 5.1.
    # Apply the Windows argv quoting rules, including trailing backslashes.
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Measure-SmolBoot {
    param(
        [Parameter(Mandatory)][string]$Qemu,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 100)][int]$Runs = 1,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 30,
        [string]$ReadyPattern = 'bsd@shell\$\s*$',
        [Parameter(Mandatory)][string]$LogDirectory
    )
    $promptRegex = New-Object Text.RegularExpressions.Regex($ReadyPattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(1))
    $null = New-Item -ItemType Directory -Force -Path $LogDirectory
    for ($run = 1; $run -le $Runs; $run++) {
        $id = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $prefix = Join-Path ([IO.Path]::GetFullPath($LogDirectory)) "boot-$id"
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $process = New-Object Diagnostics.Process
        $client = $null
        $stdout = $null
        $stderr = $null
        $started = $false
        $transcript = ''
        $clock = New-Object Diagnostics.Stopwatch
        try {
            # Listen before launching: QEMU connects as a client, so no port reservation
            # race or timer-distorting retry loop waiting for QEMU's listener is needed.
            $listener.Start()
            $port = $listener.LocalEndpoint.Port
            $accept = $listener.AcceptTcpClientAsync()
            $qemuArguments = @($Arguments)
            $serialIndex = [Array]::IndexOf($qemuArguments, '-serial')
            if ($serialIndex -lt 0) { throw 'Benchmark requires a serial console argument.' }
            $qemuArguments[$serialIndex + 1] = "tcp:127.0.0.1:$port"
            $qemuArguments += @('-monitor', 'none')
            if ($qemuArguments -notcontains '-snapshot') { $qemuArguments += '-snapshot' }
            $process.StartInfo.FileName = $Qemu
            $process.StartInfo.Arguments = ($qemuArguments | ForEach-Object { ConvertTo-SmolNativeArgument $_ }) -join ' '
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.CreateNoWindow = $true
            $process.StartInfo.RedirectStandardOutput = $true
            $process.StartInfo.RedirectStandardError = $true
            $process.StartInfo.RedirectStandardInput = $true
            $clock.Start() # Includes process creation, firmware, kernel and userspace startup.
            $started = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $buffer = New-Object byte[] 16384
            $read = $null
            $stream = $null
            $queriesAnswered = 0
            $shellMs = $null
            $readyMs = $null
            $marker = "SMOLBSD_BENCH_$id"
            while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
                if ($process.HasExited) { throw "QEMU exited with code $($process.ExitCode) before userspace was confirmed." }
                if (!$client -and $accept.IsCompleted) {
                    $client = $accept.GetAwaiter().GetResult()
                    $client.NoDelay = $true
                    $stream = $client.GetStream()
                    $stream.WriteTimeout = 1000
                    $read = $stream.ReadAsync($buffer, 0, $buffer.Length)
                }
                if ($read -and $read.IsCompleted) {
                    $count = $read.GetAwaiter().GetResult()
                    if ($count -eq 0) { throw 'Guest serial connection closed before userspace was confirmed.' }
                    $transcript += [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
                    # Answer resize(1)'s terminal query promptly, as a real terminal would.
                    # Use [char]27 because Windows PowerShell 5.1 has no `e escape.
                    $queries = [regex]::Matches($transcript, ([char]27 + '\[6n')).Count
                    while ($queriesAnswered -lt $queries) {
                        $reply = [Text.Encoding]::ASCII.GetBytes(([char]27 + '[24;80R'))
                        $stream.Write($reply, 0, $reply.Length)
                        $queriesAnswered++
                    }
                    $plain = [regex]::Replace($transcript, ([char]27 + '\[[0-?]*[ -/]*[@-~]'), '').Replace("`r", '')
                    if ($null -eq $shellMs -and $promptRegex.IsMatch($plain)) {
                        $shellMs = $clock.Elapsed.TotalMilliseconds
                        # Echoing this command cannot produce the complete random marker.
                        $command = [Text.Encoding]::ASCII.GetBytes("printf '\nSMOLBSD_BENCH_%s\n' '$id'`n")
                        $stream.Write($command, 0, $command.Length)
                    }
                    if ($null -ne $shellMs -and $plain -match "(?m)^$marker`$") {
                        $readyMs = $clock.Elapsed.TotalMilliseconds
                        break
                    }
                    $read = $stream.ReadAsync($buffer, 0, $buffer.Length)
                } else {
                    [Threading.Thread]::Sleep(1)
                }
            }
            if ($null -eq $readyMs) {
                throw "Timed out after $TimeoutSeconds seconds waiting for a shell command response. This benchmark needs a shell image; check -ReadyPattern."
            }
            $kernelMs = $null
            if ($transcript -match 'kernel boot time:\s*(\d+)ms') { $kernelMs = [int]$Matches[1] }
            [pscustomobject]@{
                Run = $run
                LaunchToUserspaceMs = [Math]::Round($readyMs, 2)
                LaunchToShellMs = [Math]::Round($shellMs, 2)
                GuestKernelMs = $kernelMs
                SerialLog = "$prefix.serial.log"
            }
        } catch {
            throw "Benchmark run $run failed: $($_.Exception.Message) Logs: $prefix.*.log"
        } finally {
            $clock.Stop()
            if ($client) { $client.Dispose() }
            $listener.Stop()
            if ($started -and !$process.HasExited) {
                $process.Kill()
                $null = $process.WaitForExit(5000)
            }
            [IO.File]::WriteAllText("$prefix.serial.log", $transcript)
            if ($stdout) { [IO.File]::WriteAllText("$prefix.stdout.log", $stdout.GetAwaiter().GetResult()) }
            if ($stderr) { [IO.File]::WriteAllText("$prefix.stderr.log", $stderr.GetAwaiter().GetResult()) }
            $process.Dispose()
        }
    }
}

Export-ModuleMember -Function Get-SmolImageIdentity, Save-SmolDownload, Save-SmolImage, Save-SmolKernel, Find-SmolQemu, Test-SmolHost, New-SmolQemuArguments, Measure-SmolBoot
