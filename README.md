# ix500-scan — ScanSnap iX500 open-source scanning stack for macOS

Fujitsu/PFU killed ScanSnap Manager support for the iX500 on modern macOS. This project
restores a clean scan-to-PDF workflow using only open-source software, over **USB**.

Stack: [sane-backends](https://sane-project.org) (`fujitsu` backend) + `img2pdf` for the
CLI, [NAPS2](https://naps2.com) for the GUI.

## Quick start (CLI)

Drop a stack in the ADF (lid open — that powers the scanner on), then:

```sh
scan2pdf taxes        # → ~/Documents/Scans/taxes-YYYYMMDD-HHMMSS.pdf (duplex, color, 300dpi)
scan2pdf              # → ~/Documents/Scans/scan-YYYYMMDD-HHMMSS.pdf
```

Options:

```
  -s, --simplex        front side only (default: duplex)
  -g, --gray           grayscale (default: color)
  -r, --resolution N   dpi (default: 300)
  -o, --outdir DIR     output directory (default: ~/Documents/Scans)
  -p, --png            lossless PNG intermediates — PDFs ~20x bigger (default: JPEG)
  -k, --keep-pages     keep intermediate page images next to the PDF
  -x, --scanopt ARG    pass an extra option through to scanimage (repeatable)
      --open           open the finished PDF in Preview
```

Exit codes: `0` success · `1` no scanner · `2` empty ADF / no pages · `3` PDF assembly failure.

All tools live in `bin/` here and are symlinked into `~/bin` (on PATH).

## Paychecks: scan-checks + checks-split

One PDF per paydate, duplex (front + endorsement back), checks in check-number
order, named `checksYYYYMMDD.pdf` (the date printed on the checks). Each check
becomes two consecutive PDF pages (front, then back).

**Mixed paydates / unsorted stack** (the usual case — Claude drives this):

```sh
scan-checks --staging                      # any order, no paydate needed
# ...Claude reads check numbers + dates off the scanned fronts, writes a manifest:
#    <front_page> <check_number> <YYYYMMDD>   (one line per check)
checks-split <staging.pdf> <manifest>      # → checksYYYYMMDD.pdf per paydate
```

`checks-split` is deterministic qpdf assembly: groups by paydate, sorts by check
number, validates the manifest before writing anything, and appends when a
paydate PDF already exists.

**Single known paydate, pre-sorted stack:**

```sh
scan-checks 2026-06-05   # → checks20260605.pdf directly
```

Here the sort is physical: stack the checks **face up, lowest check number on
top**, then flip the whole stack face-down into the feeder, top edge first (the
iX500 feeds from the bottom). Re-running the same paydate **appends** (for
stacks over the ~50-sheet ADF limit, or a straggler check); `--replace` starts
the paydate over.

Scans use `--ald` (auto length detection — pages trimmed to actual check height)
and `--swdeskew`. A duplex scan always yields an even page count; an odd count
triggers a multifeed warning (two checks stuck together).

## GUI: NAPS2

NAPS2 is installed at `/Applications/NAPS2.app`. One-time profile setup (interactive):

1. Launch NAPS2. (First launch may show a Gatekeeper confirmation — the app is signed; click Open.)
2. **Profiles → New Profile**
3. Driver: **SANE** → device **ScanSnap iX500**
4. Paper source: **ADF Duplex** (called "Feeder (front and back)" in some NAPS2 versions)
5. Resolution: **300 dpi**, Bit depth: **Color**
6. Name it **iX500 Duplex**, save, and set as default.

Then: stack in ADF → click Scan → File → Save PDF.

## Known gotchas

- **USB only. WiFi will never work** — the iX500's wireless mode uses a proprietary protocol
  that SANE/eSCL cannot speak. Don't waste time trying.
- **Quit all ScanSnap/Fujitsu software** before scanning — it holds the USB device and SANE
  will not see the scanner. Check with `pgrep -fl -i scansnap`. Leftover LaunchAgents may
  relaunch it at login — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
- **Prefer USB-2** — this model has documented flakiness on USB-3 ports. Currently connected
  through an Anker USB-C hub; if scans hang or drop mid-batch, move it to a USB-2 port or a
  powered USB-2 hub first.
- **The lid is the power switch.** Scanner invisible? Open the lid.
- No `sudo` was required for SANE on this machine (macOS 26.5.1, Homebrew sane-backends).

## When something breaks

```sh
scan-diag
```

runs every check the stack depends on (USB presence, toolchain, SANE probe, backend
enumeration, conflicting software) and prints pass/fail with a fix hint per failure.
Deeper recovery steps: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Repo layout

```
bin/scan2pdf            one-command ADF → dated PDF
bin/scan-checks         paycheck scanning → checksYYYYMMDD.pdf (or --staging for mixed stacks)
bin/checks-split        manifest-driven split: per-paydate PDFs sorted by check number
bin/scan-diag           diagnostics with pass/fail summary
docs/device-options.txt full `scanimage -A` option dump for the iX500
ENVIRONMENT.md          machine/scanner state recorded at install time
TROUBLESHOOTING.md      recovery playbook
PRD-ix500-mac-scanning.md  the original spec this was built from
```
