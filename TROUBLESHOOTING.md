# Troubleshooting — iX500 + SANE on macOS

First move is always:

```sh
scan-diag
```

It checks USB presence, toolchain, SANE probe, backend enumeration, and conflicting
software, with a fix hint per failure. The sections below cover the deeper cases.

## Scanner not visible on USB

- **Open the lid** — it's the power switch.
- Reseat the cable; try a different port. **Prefer USB-2** (or a powered USB-2 hub):
  the iX500 has documented flakiness on USB-3. This machine currently connects through
  an Anker USB-C hub — that hub is the first suspect for mid-batch hangs.
- **Do not trust `system_profiler SPUSBDataType`** — it returns *empty output* on this
  macOS build (26.5.1). Check with:
  ```sh
  ioreg -p IOUSB -l -w0 | grep -i -B2 -A2 "ScanSnap"
  ```
  Expect `idVendor = 1221` (0x04c5) and `idProduct = 4907` (0x132b).

## SANE doesn't see the scanner (`scanimage -L` empty)

Checked in this order:

1. **Fujitsu software holding the device.** `pgrep -fl -i scansnap` — if anything shows,
   `pkill -i scansnap` and retry. See "Fujitsu leftovers" below for what relaunches it.
2. **USB-level probe:** `sane-find-scanner -q` should print
   `vendor=0x04c5 ... product=0x132b [ScanSnap iX500]`. If this fails, it's a USB/cable/
   power problem, not a SANE config problem — go back to the section above.
3. **Backend config:** `grep -n fujitsu "$(brew --prefix)/etc/sane.d/dll.conf"` — the
   `fujitsu` line must exist and be uncommented.
4. **Permissions:** try `sudo scanimage -L`. If sudo works where plain doesn't, something
   is wrong with USB device permissions. (Not needed on this machine as of install day —
   plain user worked fine.)

## Fujitsu leftovers on this machine

Found at install time (2026-06-11) and left in place (they don't block scanning unless
they launch something that grabs the scanner):

- `/Library/LaunchAgents/com.fujitsu.pfu.ScanSnap.AOUMonitor.plist` — relaunches the
  ScanSnap Online Update monitor at login. Harmless to scanning, but to silence it:
  ```sh
  sudo launchctl bootout system /Library/LaunchAgents/com.fujitsu.pfu.ScanSnap.AOUMonitor.plist 2>/dev/null
  launchctl bootout gui/$(id -u) /Library/LaunchAgents/com.fujitsu.pfu.ScanSnap.AOUMonitor.plist 2>/dev/null
  ```
- `/Library/LaunchAgents/com.ricoh.pfu.SshAutoLaunch.plist` — auto-launches ScanSnap Home
  when the scanner connects. **This one can grab the device.** If `scan-diag` shows
  ScanSnap processes reappearing after you killed them, unload it:
  ```sh
  launchctl bootout gui/$(id -u) /Library/LaunchAgents/com.ricoh.pfu.SshAutoLaunch.plist
  ```
  (Re-enable later with `launchctl bootstrap gui/$(id -u) <plist>` if ever wanted.)

## Duplex / batch scanning quirks

- `scan2pdf` uses the `scanimage` frontend with `--batch`. In batch mode the run **always**
  ends with `scanimage: sane_start: Document feeder out of documents` — that's the normal
  terminator, not an error. Page count is the success signal.
- Historical SANE issues (#411/#21) report `ADF Duplex` failing under `scanimage` on some
  versions. **Not reproduced here** — option negotiation with `--source 'ADF Duplex'`
  works on sane-backends from Homebrew (installed 2026-06-11). If it ever regresses, retry
  with the `scanadf` frontend:
  ```sh
  scanadf -d 'fujitsu:ScanSnap iX500:NNNN' --source 'ADF Duplex' --resolution 300 \
    --mode Color -o page-%03d.pnm
  ```
  and note here which frontend worked.
- Device name embeds a serial: discover the current one with `scanimage -L`. `scan2pdf`
  auto-discovers it on every run, so a changed serial only matters for manual commands.

## NAPS2 notes

- Installed by extracting the pkg payload to `/Applications/NAPS2.app` (the Homebrew cask's
  pkg installer needs interactive sudo, which the install session didn't have). The app's
  code signature was verified after extraction.
- First launch may show a Gatekeeper prompt — the app is signed and notarized; click Open.
- To update later: `brew install --cask naps2` from a terminal (it can ask for your
  password) — or repeat the payload-extraction trick.
- In NAPS2, the scanner must be selected with the **SANE** driver, not ICA/TWAIN.

## Nuclear option

If SANE can never be made to see the scanner again and all of the above fails:
[VueScan](https://www.hamrick.com) (paid, ~$60–100) supports the iX500 on modern macOS.
Do not bother compiling SANE from source first — the Homebrew bottle worked.
