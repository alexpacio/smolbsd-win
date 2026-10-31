"""Boot the real WHPX guest in snapshot mode and check its shell and network.

Requires Python 3 (standard library only), PowerShell, QEMU and downloaded assets.
Run from any directory: python tests/smoke.py
"""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', help='Test a specific local kernel instead of the default')
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    logs = root / "test-results"
    logs.mkdir(exist_ok=True)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    environment = os.environ.copy()
    environment['SMOL_TEST_KERNEL'] = str(Path(options.kernel).resolve()) if options.kernel else ''
    config = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
         f"& './smolbsd.ps1' run -KernelPath $env:SMOL_TEST_KERNEL -Snapshot -SerialPort {port} -DryRun | ConvertTo-Json -Depth 4"],
        cwd=root, env=environment, capture_output=True, text=True, check=True,
    )
    launch = json.loads(config.stdout)
    transcript = ""
    with (logs / "qemu.log").open("w", encoding="utf-8") as qemu_log:
        process = subprocess.Popen(
            [launch["Executable"], *launch["Arguments"]],
            cwd=root, stdin=subprocess.DEVNULL, stdout=qemu_log,
            stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        connection = None
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"QEMU exited with {process.returncode}; see {logs / 'qemu.log'}")
                try:
                    connection = socket.create_connection(("127.0.0.1", port), timeout=1)
                    break
                except OSError:
                    time.sleep(0.1)
            if connection is None:
                raise TimeoutError("QEMU serial listener did not start")
            connection.settimeout(1)
            sent = False
            answered_queries = 0
            while time.monotonic() < deadline:
                try:
                    data = connection.recv(65536)
                except socket.timeout:
                    continue
                if not data:
                    raise RuntimeError("Serial console closed before the test finished")
                chunk = data.decode("utf-8", errors="replace")
                transcript += chunk
                print(chunk, end="", flush=True)
                # The image runs resize(1) before showing its shell prompt.
                queries = transcript.count('\x1b[6n')
                if queries > answered_queries:
                    connection.sendall(b'\x1b[24;80R' * (queries - answered_queries))
                    answered_queries = queries
                plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", transcript)
                if not sent and re.search(r"bsd@shell\$\s*$", plain):
                    # Split the marker so an echoed command cannot be mistaken for success.
                    command = (
                        "sysctl kern.ostype kern.osrelease; ifconfig vioif0; "
                        "ready=no; for n in 1 2 3 4 5 6; do "
                        "if ping -n -c 1 -w 3 10.0.2.2; then ready=yes; break; fi; sleep 2; done; "
                        "if [ $ready = yes ] && ping -c 3 -w 10 example.com; then "
                        "printf '\\nSMOLBSD_%s\\n' 'PASS'; "
                        "else printf '\\nSMOLBSD_%s\\n' 'FAIL'; fi\n"
                    )
                    connection.sendall(command.encode("ascii"))
                    sent = True
                lines = transcript.replace('\r', '')
                if re.search(r"(?:^|\n)SMOLBSD_FAIL(?:\n|$)", lines):
                    raise RuntimeError("Guest network check failed")
                if re.search(r"(?:^|\n)SMOLBSD_PASS(?:\n|$)", lines):
                    if "kern.ostype = smolBSD" not in transcript:
                        raise RuntimeError("Expected smolBSD guest output")
                    print("\nPASS: WHPX guest boot, shell, NAT and DNS; disk changes discarded.")
                    return
            raise TimeoutError("Guest did not complete the smoke test within 90 seconds")
        finally:
            if connection is not None:
                connection.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            (logs / "serial.log").write_text(transcript, encoding="utf-8")


if __name__ == "__main__":
    main()
