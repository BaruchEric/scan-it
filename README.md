# scan-it

Open-source ScanSnap iX500 document-scanning stack for macOS — SANE-based CLI tools (scan2pdf, scan-checks, checks-split, checks-normalize, checks-report, scan-diag, scan-batch, batch-file) that turn ADF stacks into dated, ordered PDFs over USB.

## TL;DR

- **What:** Restores a clean scan-to-PDF workflow for the Fujitsu ScanSnap iX500 on modern macOS, where Fujitsu/PFU killed ScanSnap Manager support — using only open-source software, over USB.
- **How:** SANE (`scanimage`) drives the scanner; bash tools in `bin/` handle acquisition, PDF assembly (qpdf), and post-processing. NAPS2 covers the GUI path.
- **Stack:** bash · SANE/sane-backends · qpdf · NAPS2 (GUI). No deploy target — local tooling, symlinked into `~/bin`.
- **Run it:** drop a stack in the ADF (lid open powers the scanner on), then `scan2pdf taxes` → `~/Documents/Scans/taxes-YYYYMMDD-HHMMSS.pdf` (duplex, color, 300 dpi).
- **Diagnose:** `scan-diag` runs every check the stack depends on and prints pass/fail with fix hints.

## Overview

Eight CLI tools live in `bin/` (symlinked into `~/bin`, on PATH):

| Tool | What it does |
|------|--------------|
| `scan2pdf` | Scan an ADF stack to a dated multi-page PDF. Duplex/color/300 dpi by default; `-s` simplex, `-g` gray, `-r N` dpi, `-o DIR` outdir, `-p` lossless PNG intermediates, `-k` keep page images, `-x ARG` pass-through to `scanimage`, `--open` opens the PDF. Exit codes: 0 success · 1 no scanner · 2 empty ADF · 3 PDF assembly failure. |
| `scan-checks` | Scan employee paychecks duplex (front + endorsement back) into one PDF per paydate (`checksYYYYMMDD.pdf`), pages in check-number order. Wraps `scan2pdf`; re-running a paydate appends, `--replace` starts over, `--staging` scans an unsorted stack for the manifest workflow. |
| `checks-split` | Split a duplex staging PDF into per-paydate PDFs from a manifest (front/back page, check number, date, rotations), sorted by check number, validated before writing. Normalizes each check individually (via `checks-normalize --page`) before assembling the batch, so output pages are already uniform; appends to existing paydate PDFs without re-encoding their pages. |
| `checks-normalize` | Make check pages uniform: trim scanner backing (guarded — border must read as backing, the box must be sheet-sized, and the crop must remove ≥15%; the largest qualifying box across descending fuzz levels wins, so washed-out sheets are recovered whole), deskew, rotate portrait backs to landscape (bank-image convention). `--page <in> <out.jpg> <front\|back>` normalizes one rendered page (used by checks-split); PDF mode rebuilds an existing PDF in place and passes already-normalized pages through untouched, so re-runs are stable. Warns on odd page counts. |
| `checks-report` | Per-paydate summary from a data file (`<check_number> <paydate> <amount> <signed>`): check counts, number sequences, missing numbers, period totals, unsigned checks, grand total. |
| `scan-diag` | Diagnostics for the iX500 + SANE stack — colored pass/fail summary with a fix hint per failure. Changes nothing; safe any time. |
| `scan-batch` | Scan a heterogeneous stack in chunks (paper sensor auto-resumes between chunks; press Enter or wait 60 s idle to end the batch). Exit codes: 0 success · 1 no scanner / device lost / jam · 2 no pages scanned · 64 usage · 66 bad `--resume` dir · 130 interrupted. |
| `batch-file` | Validate, classify, rotate, merge, rename, and file the staged pages produced by `scan-batch`. Reads the manifest Claude writes to `<staging>/manifest.json`; refuses to write unless every scanned page is accounted for exactly once. Exit codes: 0 success · 1 validation failure (nothing written) · 2 assembly failure · 64 usage · 66 not a staging dir. |

## Paycheck workflow

**Mixed paydates / unsorted stack** (the usual case — Claude drives this):

```sh
scan-checks --staging                 # any order, orientation, or side
# Claude reads each scanned pair and writes a manifest, one line per check:
#   <front_page> <back_page> <check_number> <YYYYMMDD> <front_rot> <back_rot>
checks-split <staging.pdf> <manifest> # → checksYYYYMMDD.pdf per paydate,
                                      #   each check normalized individually
```

**Single known paydate, pre-sorted stack:**

```sh
scan-checks 2026-06-05                # → checks20260605.pdf directly
checks-normalize checks20260605.pdf   # raw (never-split) scans still need this
```

The sort is physical: stack checks face up, lowest check number on top, then flip the whole stack face-down into the feeder, top edge first (the iX500 feeds from the bottom). Scans use `--ald` (auto length detection) and `--swdeskew`; an odd page count from a duplex scan triggers a multifeed warning.

## Mixed batches

For mixed stacks containing receipts, invoices, contracts, paychecks, and anything else in the same feeder run — Claude drives this end-to-end:

**Step 1 — Scan (you drive the feeder, Claude watches):**

```sh
scan-batch                    # feed paper in chunks; the iX500 paper sensor
                              # auto-resumes between chunks; press Enter or
                              # wait 60 s idle to end the batch
```

`scan-batch` deposits page images into a timestamped staging directory (e.g. `~/Documents/Scans/.batches/batch-20260611-143022/`).

**Step 2 — Classify (Claude reads and sorts):**

Claude opens each scanned sheet, reads it with OCR, and sorts it into buckets: receipts, invoices, paychecks, contracts, statements, letters, misc. Claude prints a summary table and **waits for the user's "finalize" confirmation** before writing anything. Ambiguous items go to a `review/` bucket with the reason noted — Claude never silently guesses.

**Step 3 — File (Claude writes the manifest, batch-file executes):**

Once the user confirms, Claude writes `<staging>/manifest.json` describing every page's destination. Then:

```sh
batch-file <staging-dir>      # validates manifest, rotates/merges/renames,
                              # files each document, refuses if any page is
                              # unaccounted for
```

**Output layout under `~/Documents/Scans/`:**

```
receipts/       receipt-2026-06-08-home-depot$45.23.pdf   + .json sidecar
invoices/       invoice-2026-06-01-acme-corp$1200.00.pdf  + .json sidecar
contracts/      contract-2026-05-15-lease-renewal.pdf     + .json sidecar
statements/     statement-2026-06-01-chase-checking.pdf   + .json sidecar
letters/        letter-2026-06-10-irs-notice.pdf          + .json sidecar
taxes/          tax-2026-04-15-1099-misc.pdf              + .json sidecar
misc/           misc-2026-06-11-unknown.pdf               + .json sidecar
paychecks/      checks20260605.pdf  (via checks-split, per-check normalized)
review/         items Claude could not classify with confidence
entities.json   entity registry (personal + each business LLC)
index.jsonl     one line per filed document (all types)
```

**Entities.** Documents can be attributed to an entity — personal vs. a specific
business (LLC). The registry lives at `~/Documents/Scans/entities.json` (slugs +
display names); a manifest document may carry an optional `"entity": "<slug>"`,
which `batch-file` validates against the registry and uses to file into a
per-entity subfolder, e.g. `taxes/rio-laundromat/`, `receipts/personal/`. The
entity is recorded in the sidecar and `index.jsonl`. Documents without an entity
file at the type-folder root as before; paychecks ignore entity.

Each `.json` sidecar contains the full OCR text, extracted fields (date, vendor, amount, etc.), and provenance (source scan, batch ID). Searchable text layers are embedded in the PDFs when `ocrmypdf` is installed (`brew install ocrmypdf` — optional; filing works without it). Paychecks are handed off to `checks-split` — which normalizes each check individually — and land in `paychecks/` exactly as the dedicated paycheck flow.

## GUI: NAPS2

NAPS2 (`/Applications/NAPS2.app`) covers point-and-click scanning. One-time profile: Profiles → New Profile → Driver **SANE** → device **ScanSnap iX500** → ADF Duplex, 300 dpi, Color → save as default. Then stack → Scan → Save PDF.

## Getting Started

The tools assume SANE can see the iX500 over USB (see `ENVIRONMENT.md` for the recorded machine/scanner baseline). If anything misbehaves:

1. `scan-diag` — pass/fail with fix hints.
2. `TROUBLESHOOTING.md` — known failure modes and fixes.

## Repo Layout

```
bin/                  # the eight CLI tools (symlinked into ~/bin)
docs/                 # device-options.txt (full scanimage option dump), plans/specs
test/                 # bats test suites: scan-batch.bats, batch-file.bats, checks-normalize.bats, stubs/
ENVIRONMENT.md        # machine + scanner baseline recorded at preflight
PRD-ix500-mac-scanning.md   # original product requirements
TROUBLESHOOTING.md    # failure modes and fixes
```

## Status

In active use for document and paycheck scanning. The check workflow (scan → manifest → split, normalizing each check → report) shipped 2026-06-11; per-check normalization inside checks-split landed 2026-06-12. The mixed-batch workflow (scan-batch + batch-file) shipped 2026-06-11 (see `docs/superpowers/`). Automated bats suites cover scan-batch (8 tests), batch-file (18 tests), and checks-normalize (8 tests); run with `bats test/`.
