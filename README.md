# smolbsd-win

Run smolBSD on an **x64 Windows host** with native QEMU **WHPX** acceleration.
The upstream [NetBSDfr/smolBSD](https://github.com/NetBSDfr/smolBSD) repository
is pinned as the `smolBSD/` Git submodule; Windows support lives in this parent
repository and does not modify that checkout.

## Quick start

Requirements:

- Windows 10/11 x64, with CPU virtualization enabled in firmware.
- **Windows Hypervisor Platform** enabled in Windows Features, followed by a reboot.
- A recent [QEMU for Windows](https://www.qemu.org/download/#windows) build with the
  `whpx` accelerator and its `hyperv=off` option. Tested with **11.0.50
  (v11.0.0-12631-g54e84cdc7a)**. The launcher searches
  `PATH` and `C:\Program Files\qemu`; use `-Qemu` for another installation.
- Windows PowerShell 5.1 or PowerShell 7, Git, and internet access for setup.

From the repository directory:

```powershell
git submodule update --init --recursive
# If local script execution is blocked, allow it in this process only:
Set-ExecutionPolicy -Scope Process Bypass
.\smolbsd.ps1 setup
.\smolbsd.ps1 run
```

`setup` checks host prerequisites, downloads the amd64 kernel and the public
`bsdshell-amd64:latest` image, and verifies their SHA256 checksums. Downloads
live under ignored `data/`, outside the submodule. Subsequent setup calls keep
existing assets, including any changes made inside the guest. Failed downloads
do not replace existing files. No ORAS, jq, Unix shell, make, WSL or Docker is
required for running a published image.

In the serial console, press **Ctrl+A**, release, then **X** to stop QEMU.
Shut down the guest cleanly before exiting when preserving disk writes.
Use `-Snapshot` for a disposable session; all disk changes are discarded at exit.

If Windows Hypervisor Platform is missing, enable it from an elevated PowerShell
and reboot (the scripts do not change Windows features automatically):

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
```

## Commands

```powershell
.\smolbsd.ps1 doctor
.\smolbsd.ps1 images
.\smolbsd.ps1 pull bsdshell-amd64:latest
.\smolbsd.ps1 kernfetch
.\smolbsd.ps1 run -Memory 512 -Cpus 2 -Snapshot
.\smolbsd.ps1 run -NoNetwork
.\smolbsd.ps1 run -Forward tcp:2222:22,udp:5353:53
.\smolbsd.ps1 run -DryRun | ConvertTo-Json -Depth 4
.\smolbsd.ps1 bench
.\smolbsd.ps1 bench -Runs 5
```

## Boot benchmark

`bench` measures host wall-clock elapsed time with a monotonic stopwatch, starting
immediately before creating the QEMU process. It waits for the shell prompt, sends
a `printf` command containing a random token, and stops when the guest prints the
complete token on its own line. An echoed command cannot count as success.

```powershell
.\smolbsd.ps1 bench -Runs 5
.\smolbsd.ps1 bench -Runs 5 -Memory 512 -Cpus 2
.\smolbsd.ps1 bench -NoNetwork -TimeoutSeconds 60
```

The output includes each run and the median/minimum/maximum:

| Field | Measurement |
| --- | --- |
| `LaunchToUserspaceMs` | QEMU process launch to successful guest shell command response. |
| `LaunchToShellMs` | QEMU process launch to observed shell prompt. |
| `GuestKernelMs` | Kernel-reported boot duration, when present in the console log. |
| `SerialLog` | Saved console transcript for this run. |

The primary measurement includes process creation, firmware, kernel and userspace
startup, plus serial observation and a command round trip. It is an upper bound
on when a usable shell becomes available, rather than the instant `init` first
executes. Downloads and host prerequisite checks are outside the timer. It does
not wait for networking or application services. Runs use the normal host file
cache; this is not a cold-cache benchmark.

The host listens before launching QEMU, and answers the guest's terminal-size
query immediately. Every run uses a disposable disk snapshot and stops its QEMU
process afterwards, including on timeout. Console and QEMU diagnostic logs are
saved under `data/bench/`. The default timeout is 30 seconds per run.

The default readiness pattern matches the published `bsdshell` prompt. Other
interactive shell images can use `-ReadyPattern '<regex>'`; the matched shell
must accept the `printf` command. Service-only images without a shell are not
supported. `bench` owns its serial connection, so `-SerialPort` and `-DryRun` are
rejected. Normal resource, kernel, image and networking options still apply.

On this host, five default runs measured **820.03 ms median**, **818.15–837.20 ms**
from launch to command confirmation. Shell prompts appeared in 802.66–808.18 ms;
the kernel reported 148–157 ms. These are sample results, not performance guarantees.

Run the benchmark integration checks after setup with:

```powershell
.\tests\bench.Tests.ps1
```

## Other images and options

For a different published service, use the same image name for setup and run:

```powershell
.\smolbsd.ps1 setup sshd-amd64:latest
.\smolbsd.ps1 run sshd-amd64:latest -Forward tcp:2222:22
```

Availability and guest configuration depend on the upstream image. A forward
does not install or start a service in the guest. Forwards bind to `127.0.0.1`
on the host. Outbound networking uses QEMU user networking (NAT) by default.

Additional options:

| Option | Purpose |
| --- | --- |
| `-DataDirectory D:\smol-data` | Store downloads elsewhere. |
| `-ImagePath D:\guests\custom.img` | Boot an existing raw image. |
| `-KernelPath D:\guests\smolbsd` | Boot a supplied compatible amd64 kernel. |
| `-RootDisk NAME=customroot` | Override the default `NAME=<service>root` GPT label. |
| `-Qemu 'C:\Program Files\qemu\qemu-system-x86_64.exe'` | Select the native QEMU executable. |
| `-SerialPort 4444` | Expose a raw TCP serial console on loopback; boot waits for a client. |
| `-Force` | For `pull`, `kernfetch` or `setup`, replace existing assets. Replacing an image discards guest changes. |

`-DryRun` returns an executable and argument array without launching QEMU or
changing files; local assets must already exist. Custom assets are not downloaded
or checksum-verified by `run`. With custom images, set `-RootDisk` if their label
does not match the selected service.

## Windows compatibility decisions

Based on [upstream issue #81](https://github.com/NetBSDfr/smolBSD/issues/81):

- Request `-accel whpx,hyperv=off` and
  `-cpu kvm64-v1,+invtsc,vmware-cpuid-freq=off`. There is no implicit TCG fallback.
  The issue reports failures with `host` and `max` CPU models.
- Disable Hyper-V guest enlightenments while retaining WHPX acceleration. With
  this host's QEMU defaults the kernel could not attach its paravirtual bus and
  stopped at `root device:`. NetBSD's
  [bus attachment code](https://github.com/NetBSDfr/NetBSD-src/blob/netbsd-smol-11/sys/arch/amd64/amd64/amd64_mainbus.c)
  accepts a limited set of hypervisor identities. `vmware-cpuid-freq=off` also
  avoids the VMware identity used by some newer WHPX implementations. If QEMU
  rejects `whpx-accel.hyperv`, select a newer build with `-Qemu`.
- Keep upstream's `microvm,rtc=on,acpi=off,pic=off`, VirtIO MMIO block/network
  devices, and `console=com` serial console.
- Fetch public GHCR OCI manifests and their raw disk blobs directly. Ignore
  remote filename annotations: `bsdshell-amd64:latest` becomes
  `data/images/bsdshell-amd64_latest.img`, avoiding NTFS alternate data streams.
- Fetch the kernel directly from `https://smolbsd.org/assets/amd64/smolbsd`,
  matching the pinned upstream Makefile, rather than requiring BSD make.
- Verify the image layer's declared size and SHA256, and the kernel's published
  `.sha256` sidecar. These are integrity checks, not publisher signature checks.

The submodule is pinned, but the upstream image tag and kernel download URL are
mutable. Keep known working assets or use explicit local paths for reproducible
deployments. This wrapper supports running public amd64 raw-image artifacts;
upstream image builds, private registries, OCI indexes, GUI, and 9p host-directory
sharing are outside its scope. In particular, it does not port the upstream
Unix image builder to Windows.

QEMU's [accelerator documentation](https://www.qemu.org/docs/master/system/introduction.html)
and [microvm documentation](https://www.qemu.org/docs/master/system/i386/microvm.html)
describe the underlying platform. `doctor` checks prerequisites; the actual boot
is the definitive WHPX compatibility check.

## Validation

```powershell
.\tests\launcher.Tests.ps1
# Optional integration test; Python 3 standard library only, after setup:
python .\tests\smoke.py
```

The offline PowerShell tests cover image names, Windows paths, argument handling,
network options, checksum/size failures, and preservation of existing files.
The integration test starts QEMU with WHPX and a snapshot, waits for the shell,
prints the guest version, and checks NAT connectivity plus DNS/external
connectivity. It terminates its QEMU process on success or failure and saves logs
to `test-results/`. Its external network check requires access to `example.com`.
It waits for the guest's initial address probing to finish before checking
connectivity; the IPv4 address is briefly marked `TENTATIVE` during startup.

Verified on this Windows x64 host on 2026-10-31: PowerShell 5.1, the QEMU build
above, smolBSD `11.0_STABLE`, a working serial shell, NAT and DNS, and three
successful external ping replies. The kernel reported approximately 190 ms boot
time (userspace and address probing take longer). Upstream submodule revision:
`7ceba102d5a434aae39f6fa9c24fcf534b7a1526`.
