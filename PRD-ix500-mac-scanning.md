# PRD: ScanSnap iX500 Open-Source Scanning Stack on macOS

**Project codename:** `ix500-scan`
**Target executor:** Claude Code (agentic execution, phase-gated)
**Target machine:** Eric's Mac (Apple Silicon or Intel — detect at runtime)
**Status:** Ready for execution
**Last updated:** 2026-06-11

---

## 1. Problem Statement

Fujitsu/PFU terminated ScanSnap Manager (Nov 2024) and the iX500 is no longer supported on macOS Sequoia+. The scanner hardware is fully functional. Goal: restore a clean, reliable scan-to-PDF workflow on macOS using only open-source software, connected via **USB** (WiFi is not possible — the iX500's wireless uses a proprietary protocol unsupported by SANE/eSCL).

## 2. Goals

1. iX500 detected and scannable via the SANE `fujitsu` backend over USB.
2. A one-command CLI workflow: drop a stack in the ADF → run one command → get a dated, duplex, multi-page PDF in a target folder.
3. NAPS2 installed and configured as the GUI option (profile: SANE driver, ADF Duplex, 300 dpi, save to PDF).
4. Diagnostics script for future troubleshooting.

## 3. Non-Goals (anti-feature-creep)

- ❌ WiFi/network scanning (impossible via open source for this model — do not attempt)
- ❌ OCR / searchable PDFs (future phase if ever needed; not now)
- ❌ Document management (Paperless-ngx etc.)
- ❌ AirSane/eSCL bridging to Image Capture (known broken: advertises as flatbed, breaks duplex)
- ❌ Compiling SANE from source (use Homebrew bottle unless it fails)
- ❌ Firmware extraction (`.nal` files are for S300/S1300 series only — **not needed for iX500**)

## 4. Constraints & Assumptions

- Scanner connected by **USB**, ideally a USB-2 port or powered USB-2 hub (documented USB-3 flakiness with this model).
- Any Fujitsu software (ScanSnap Home/Manager) must be quit/disabled — it holds the USB device and blocks SANE.
- Homebrew assumed present; install if missing (ask user first before installing Homebrew itself).
- All scripts live in `~/Arik/dev/tools/ix500-scan/` (follow devhub conventions; register the project with devhub after Phase 4).
- Output PDFs default to `~/Documents/Scans/`.

## 5. Architecture Overview

```
[iX500] --USB--> [sane-backends (fujitsu backend)]
                       ├──> scanimage CLI ──> PNG pages ──> img2pdf ──> dated PDF
                       └──> NAPS2.app (GUI, SANE driver profile)
```

---

## Phase 0 — Preflight & Environment Detection

**Tasks:**
1. Detect CPU arch (`uname -m`) and macOS version (`sw_vers`). Record in `ENVIRONMENT.md`.
2. Check Homebrew: `brew --version`. If missing → STOP and ask user before installing.
3. Check for running Fujitsu software: `pgrep -fl -i "scansnap"`. If found, quit it and check for LaunchAgents/LaunchDaemons (`ls ~/Library/LaunchAgents /Library/LaunchAgents 2>/dev/null | grep -i pfu\|scansnap`). Report findings; ask user before unloading any agents.
4. Confirm scanner is plugged in and powered (lid open): `system_profiler SPUSBDataType | grep -A5 -i "ix500\|04c5"`. Expect vendor `0x04c5`, product `0x132b`.

**Gate:** USB device visible to macOS. If not visible: instruct user to check cable/port (prefer USB-2), open scanner lid, then re-run. Do not proceed.

## Phase 1 — Install SANE Backends

**Tasks:**
1. `brew install sane-backends` (and `brew install img2pdf` for PDF assembly — preferred over ImageMagick `convert` for lossless, smaller PDFs).
2. Verify: `sane-find-scanner -q` → expect `vendor=0x04c5 ... product=0x132b [ScanSnap iX500]`.
3. Verify backend enumeration: `scanimage -L` → expect `device 'fujitsu:ScanSnap iX500:NNNN'`.
4. If step 3 fails but step 2 succeeded:
   - Re-check Phase 0 step 3 (Fujitsu software grabbing device).
   - Try `sudo scanimage -L` (permissions issue — report to user if sudo is required, note it in TROUBLESHOOTING.md).
   - Check `$(brew --prefix)/etc/sane.d/dll.conf` contains an uncommented `fujitsu` line.
5. Capture full option list for the device: `scanimage -d '<device>' -A > docs/device-options.txt`. Confirm `--source 'ADF Duplex'` exists.

**Gate:** `scanimage -L` lists the fujitsu device AND `ADF Duplex` appears in options. Commit `docs/device-options.txt`.

## Phase 2 — Smoke Test Scans

**Tasks:**
1. Single-page simplex test: one sheet in ADF →
   `scanimage -d '<device>' --source 'ADF Front' --resolution 300 --mode Color --format=png > test/simplex.png`
2. Duplex multi-page batch test: 3 sheets in ADF →
   `scanimage -d '<device>' --source 'ADF Duplex' --resolution 300 --mode Color --format=png --batch=test/page-%03d.png`
3. Verify: 6 PNGs produced, open one with `qlmanage -p` or report dimensions via `sips -g pixelWidth -g pixelHeight`.
4. If duplex source errors (known historical SANE issues #411/#21 with ADF Duplex in scanimage): retry with `scanadf` frontend; document which frontend works in `TROUBLESHOOTING.md`.

**Gate:** Duplex batch scan produces correct page count with both sides captured. User visually confirms quality before Phase 3.

## Phase 3 — `scan2pdf` CLI Tool

Create `scan2pdf` (bash or zsh, shellcheck-clean) installed to `~/bin` or symlinked into PATH.

**Spec:**
```
scan2pdf [options] [output-name]
  -s, --simplex        front side only (default: duplex)
  -g, --gray           grayscale (default: color)
  -r, --resolution N   dpi (default: 300)
  -o, --outdir DIR     default ~/Documents/Scans
  -k, --keep-pages     keep intermediate PNGs (default: delete)
```

**Behavior:**
1. Auto-discover device via `scanimage -L | grep fujitsu` (fail with friendly message + pointer to diagnostics if absent).
2. Scan to temp dir with `--batch`, using the frontend determined in Phase 2.
3. Assemble with `img2pdf` → `<outdir>/<name-or-scan>-YYYYMMDD-HHMMSS.pdf`.
4. Print page count, file size, and output path. Open in Preview with `open` only if `--open` flag passed.
5. Exit codes: 0 success, 1 no scanner, 2 empty ADF/no pages, 3 assembly failure.

**Also create:** `scan-diag` — diagnostics script that runs: USB presence check, `sane-find-scanner`, `scanimage -L`, Fujitsu-process check, and prints a colored pass/fail summary.

**Gate:** End-to-end: stack in ADF → `scan2pdf taxes` → valid duplex PDF in ~/Documents/Scans. Run shellcheck clean. Test exit codes 1 and 2.

## Phase 4 — NAPS2 GUI + Documentation

**Tasks:**
1. `brew install --cask naps2` (verify cask exists; otherwise download the correct pkg — universal or arch-specific — from naps2.com and install).
2. Launch NAPS2; guide user (interactive — cannot be fully automated) to create profile: **Profiles → New → SANE Driver → ScanSnap iX500 → Source: ADF Duplex, 300 dpi, Color**. Name it "iX500 Duplex".
3. Write `README.md`: quick-start (scan2pdf usage, NAPS2 profile), known gotchas (USB-2 preference, quit ScanSnap software, no WiFi ever, sudo note if applicable), and recovery steps (`scan-diag`).
4. Register project in devhub under tools/utilities category; refresh dashboard.

**Gate:** User confirms one successful NAPS2 GUI scan + README reviewed.

---

## 6. Acceptance Criteria (overall)

- [ ] `scan-diag` passes all checks
- [ ] `scan2pdf` produces a duplex, multi-page, dated PDF in one command
- [ ] NAPS2 "iX500 Duplex" profile scans successfully
- [ ] No Fujitsu/PFU software required or running
- [ ] Repo committed in `~/Arik/dev` with README, scripts, docs/, TROUBLESHOOTING.md

## 7. Rollback / Failure Path

- If SANE detection cannot be made to work after Phase 1 retries: STOP. Document failure state in TROUBLESHOOTING.md and recommend VueScan (paid, ~$60–100) as the fallback. Do not attempt source compilation or kernel-level workarounds without explicit user approval.

## 8. Open Questions for User (ask before starting if unanswered)

1. Is the iX500 currently connected via USB-2 or USB-3/USB-C port?
2. Is ScanSnap Home/Manager still installed on this Mac? OK to disable its launch agents?
3. Preferred default: color or grayscale at 300 dpi?
