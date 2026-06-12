# Environment — recorded at Phase 0 preflight (2026-06-11)

## Machine

| Item | Value |
|---|---|
| CPU architecture | arm64 (Apple Silicon) |
| macOS version | 26.5.1 (build 25F80) |
| Homebrew | 5.1.15 (present) |

## Scanner connection

- **ScanSnap iX500 detected** via `ioreg -p IOUSB`: idVendor `1221` (0x04c5), idProduct `4907` (0x132b).
- Connected through an **Anker USB-C hub** (idVendor 0x291a). The PRD recommends a USB-2 port or
  powered USB-2 hub due to documented USB-3 flakiness with this model — if scans hang or drop
  mid-batch, try moving the scanner to a different port/hub first.
- **Quirk:** `system_profiler SPUSBDataType` returns *empty output* on this macOS build.
  Use `ioreg -p IOUSB -l -w0 | grep -i -A2 -B2 ix500` to check USB presence instead
  (`scan-diag` does this automatically).

## Fujitsu/PFU software found

- Running process at preflight: `AOUMonitor` (ScanSnap Online Update monitor) — quit during Phase 0.
- LaunchAgents present (NOT yet unloaded — see TROUBLESHOOTING.md):
  - `/Library/LaunchAgents/com.fujitsu.pfu.ScanSnap.AOUMonitor.plist` (online-update monitor; relaunches at login)
  - `/Library/LaunchAgents/com.ricoh.pfu.SshAutoLaunch.plist` (ScanSnap Home auto-launch; may grab the
    scanner when it powers on — unload if SANE reports the device busy)
- No ScanSnap Home/Manager process was running at preflight.
