# scan-it

Open-source ScanSnap iX500 document-scanning stack for macOS — SANE-based CLI tools (scan2pdf, scan-checks, checks-split, checks-normalize, checks-report, scan-diag) that turn ADF stacks into dated, ordered PDFs over USB.

## TL;DR

- **What:** Restores a clean scan-to-PDF workflow for the Fujitsu ScanSnap iX500 on modern macOS, where Fujitsu/PFU killed ScanSnap Manager support — using only open-source software, over USB.
- **How:** SANE (`scanimage`) drives the scanner; bash tools in `bin/` handle acquisition, PDF assembly (qpdf), and post-processing. NAPS2 covers the GUI path.
- **Stack:** bash · SANE/sane-backends · qpdf · NAPS2 (GUI). No deploy target — local tooling, symlinked into `~/bin`.
- **Run it:** drop a stack in the ADF (lid open powers the scanner on), then `scan2pdf taxes` → `~/Documents/Scans/taxes-YYYYMMDD-HHMMSS.pdf` (duplex, color, 300 dpi).
- **Diagnose:** `scan-diag` runs every check the stack depends on and prints pass/fail with fix hints.

## Overview

Six CLI tools live in `bin/` (symlinked into `~/bin`, on PATH):

| Tool | What it does |
|------|--------------|
| `scan2pdf` | Scan an ADF stack to a dated multi-page PDF. Duplex/color/300 dpi by default; `-s` simplex, `-g` gray, `-r N` dpi, `-o DIR` outdir, `-p` lossless PNG intermediates, `-k` keep page images, `-x ARG` pass-through to `scanimage`, `--open` opens the PDF. Exit codes: 0 success · 1 no scanner · 2 empty ADF · 3 PDF assembly failure. |
| `scan-checks` | Scan employee paychecks duplex (front + endorsement back) into one PDF per paydate (`checksYYYYMMDD.pdf`), pages in check-number order. Wraps `scan2pdf`; re-running a paydate appends, `--replace` starts over, `--staging` scans an unsorted stack for the manifest workflow. |
| `checks-split` | Deterministic qpdf assembly: split a duplex staging PDF into per-paydate PDFs from a manifest (front/back page, check number, date, rotations), sorted by check number, validated before writing, appends to existing paydate PDFs. |
| `checks-normalize` | Make every page of a check PDF uniform: render at 300 dpi, trim scanner background, deskew, rotate portrait backs to landscape (bank-image convention), rebuild in place. Idempotent — safe to re-run. |
| `checks-report` | Per-paydate summary from a data file (`<check_number> <paydate> <amount> <signed>`): check counts, number sequences, missing numbers, period totals, unsigned checks, grand total. |
| `scan-diag` | Diagnostics for the iX500 + SANE stack — colored pass/fail summary with a fix hint per failure. Changes nothing; safe any time. |

## Paycheck workflow

**Mixed paydates / unsorted stack** (the usual case — Claude drives this):

```sh
scan-checks --staging                 # any order, orientation, or side
# Claude reads each scanned pair and writes a manifest, one line per check:
#   <front_page> <back_page> <check_number> <YYYYMMDD> <front_rot> <back_rot>
checks-split <staging.pdf> <manifest> # → checksYYYYMMDD.pdf per paydate
checks-normalize checksYYYYMMDD.pdf   # crop + deskew + uniform landscape pages
```

**Single known paydate, pre-sorted stack:**

```sh
scan-checks 2026-06-05   # → checks20260605.pdf directly
```

The sort is physical: stack checks face up, lowest check number on top, then flip the whole stack face-down into the feeder, top edge first (the iX500 feeds from the bottom). Scans use `--ald` (auto length detection) and `--swdeskew`; an odd page count from a duplex scan triggers a multifeed warning.

## GUI: NAPS2

NAPS2 (`/Applications/NAPS2.app`) covers point-and-click scanning. One-time profile: Profiles → New Profile → Driver **SANE** → device **ScanSnap iX500** → ADF Duplex, 300 dpi, Color → save as default. Then stack → Scan → Save PDF.

## Getting Started

The tools assume SANE can see the iX500 over USB (see `ENVIRONMENT.md` for the recorded machine/scanner baseline). If anything misbehaves:

1. `scan-diag` — pass/fail with fix hints.
2. `TROUBLESHOOTING.md` — known failure modes and fixes.

## Repo Layout

```
bin/                  # the six CLI tools (symlinked into ~/bin)
docs/                 # device-options.txt (full scanimage option dump), plans/specs
ENVIRONMENT.md        # machine + scanner baseline recorded at preflight
PRD-ix500-mac-scanning.md   # original product requirements
TROUBLESHOOTING.md    # failure modes and fixes
test/                 # (empty placeholder)
```

## Status

In active use for document and paycheck scanning. The check workflow (scan → manifest → split → normalize → report) shipped 2026-06-11 (see `docs/superpowers/`). `test/` is an empty placeholder — the tools are verified by `scan-diag` and real scans rather than an automated suite.
