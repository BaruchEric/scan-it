# scan-it

Open-source ScanSnap iX500 document-scanning stack for macOS: SANE-driven bash CLIs that turn ADF paper stacks into dated, ordered PDFs over USB — built because Fujitsu/PFU dropped ScanSnap Manager on modern macOS.

## TL;DR

- **What:** Restores a full scan-to-PDF workflow for the Fujitsu ScanSnap iX500 on current macOS using only open-source software, over USB.
- **How:** SANE's `scanimage` drives the scanner; eight bash tools in `bin/` handle acquisition, PDF assembly, check normalization, and manifest-driven filing.
- **Stack:** bash · SANE/sane-backends · img2pdf + qpdf · ImageMagick + poppler · jq · optional ocrmypdf · NAPS2 (GUI). No build step, no package manager.
- **Install:** symlink `bin/*` onto your `PATH` (they already live in `~/bin` on this machine).
- **Run it:** drop a stack in the ADF (open the lid to power on), then `scan2pdf taxes` → `~/Documents/Scans/taxes-YYYYMMDD-HHMMSS.pdf` (duplex, color, 300 dpi).
- **Diagnose:** `scan-diag` runs every dependency check and prints pass/fail with a fix hint per failure.

## Overview

Fujitsu/PFU discontinued ScanSnap Manager support on recent macOS, leaving the iX500 without vendor software. `scan-it` replaces it entirely with the open-source SANE stack plus a set of small, composable bash tools. There is **no application to run** — the tools are ordinary CLIs you invoke against a stack of paper in the automatic document feeder (ADF).

Three workflows are supported:

1. **Plain documents** — `scan2pdf` acquires an ADF stack into one dated multi-page PDF.
2. **Paychecks** — `scan-checks` / `checks-split` / `checks-normalize` / `checks-report` produce one uniform, check-number-ordered PDF per paydate, capturing front + endorsement back.
3. **Mixed batches** — `scan-batch` continuously scans a heterogeneous stack into per-page images; a reader (Claude) classifies each page and writes a JSON manifest; `batch-file` validates it and files every document into typed folders with JSON sidecars.

A GUI path (NAPS2) is also documented for point-and-click scanning.

## Tech stack

- **bash** — all eight tools, `set -euo pipefail`. No compiled code, no dependencies bundled.
- **SANE / sane-backends** — `scanimage` (acquisition) and `sane-find-scanner` (probe); the `fujitsu` backend drives the iX500 over USB.
- **img2pdf** — assemble page images into PDFs (the primary assembler).
- **qpdf** — page-level PDF merge / split / append without re-encoding existing pages.
- **ImageMagick** (`magick`) — check normalization: guarded backing trim, deskew, rotate portrait backs to landscape.
- **poppler** (`pdftoppm`) — render PDF pages back to images for the normalization pass.
- **jq** — parse and validate the JSON manifests that drive `batch-file` and `checks-split`.
- **ocrmypdf** — *optional* searchable text layer on filed PDFs (filing works without it).
- **NAPS2** (`/Applications/NAPS2.app`) — GUI scanning via the SANE driver.
- **bats** — dev-only test suites under `test/` (not required to run the tools).

All runtime dependencies are CLI tools installed via Homebrew; the repo itself ships only bash scripts.

## Getting started

### 1. Install dependencies

```sh
brew install sane-backends img2pdf qpdf imagemagick poppler jq
brew install ocrmypdf          # optional: searchable text layer on filed PDFs
brew install --cask naps2      # optional: GUI scanning path
```

Ensure the `fujitsu` backend is enabled in SANE:

```sh
grep -n fujitsu "$(brew --prefix)/etc/sane.d/dll.conf"   # must exist, uncommented
```

### 2. Install the tools

There is no installer — the tools are symlinked from `bin/` onto your `PATH`:

```sh
mkdir -p ~/bin
for f in "$PWD"/bin/*; do ln -sf "$f" ~/bin/; done   # ensure ~/bin is on PATH
```

### 3. Verify the stack

```sh
scan-diag        # USB presence, toolchain, SANE probe, backend, conflicting software
```

Green across the board means you're ready. See `TROUBLESHOOTING.md` for any failure, and `ENVIRONMENT.md` for the recorded machine/scanner baseline.

### 4. Scan

```sh
scan2pdf taxes                        # → ~/Documents/Scans/taxes-YYYYMMDD-HHMMSS.pdf
```

### Configuration

- **Output root:** defaults to `~/Documents/Scans` (paychecks under `~/Documents/Scans/paychecks`); override per-command with `-o, --outdir DIR`.
- **Scan defaults:** duplex, color, 300 dpi; flip with `-s` (simplex), `-g` (gray), `-r N` (dpi).
- **`scan-batch` env vars:** `SCAN_BATCH_SCANIMAGE` (path to `scanimage`), `SCAN_BATCH_POLL_SECS` (paper-sensor poll interval, default 2), plus `--idle N` (end batch after N idle seconds, default 60).
- **Entities:** `~/Documents/Scans/entities.json` registers personal + per-business (LLC) slugs; a manifest document may carry `"entity": "<slug>"` so `batch-file` files it into a per-entity subfolder.

## Scripts / commands

All eight live in `bin/` and are symlinked onto `PATH`.

| Tool | What it does |
|------|--------------|
| `scan2pdf` | Scan an ADF stack to a dated multi-page PDF. Duplex/color/300 dpi by default; `-s` simplex, `-g` gray, `-r N` dpi, `-o DIR` outdir, `-p` lossless PNG intermediates, `-k` keep page images, `-x ARG` pass-through to `scanimage`, `--open` opens the PDF. Exit codes: `0` success · `1` no scanner · `2` empty ADF · `3` PDF assembly failure. |
| `scan-checks` | Scan employee paychecks duplex (front + endorsement back) into one PDF per paydate (`checksYYYYMMDD.pdf`), pages in check-number order. Wraps `scan2pdf`; re-running a paydate appends, `--replace` starts over, `--staging` scans an unsorted stack for the manifest workflow. |
| `checks-split` | Split a duplex staging PDF into per-paydate PDFs from a manifest (front/back page, check number, date, rotations), sorted by check number and validated before writing. Normalizes each check individually before assembly, so output pages are already uniform; appends to existing paydate PDFs without re-encoding their pages. |
| `checks-normalize` | Make check pages uniform: guarded scanner-backing trim (border must read as backing, box must be sheet-sized, crop must remove ≥15%), deskew, rotate portrait backs to landscape (bank-image convention). `--page <in> <out.jpg> <front\|back>` normalizes one rendered page (used by `checks-split`); PDF mode rebuilds an existing PDF in place, passing already-normalized pages through untouched so re-runs are stable. |
| `checks-report` | Per-paydate summary from a data file (`<check_number> <paydate> <amount> <signed>`): check counts, number sequences, missing numbers, period totals, unsigned checks, grand total. `-o FILE` also writes the report to a file. |
| `scan-diag` | Diagnostics for the iX500 + SANE stack — colored pass/fail summary with a fix hint per failure. Read-only; safe to run any time. |
| `scan-batch` | Continuously scan a heterogeneous stack in chunks (paper sensor auto-resumes between chunks; press Enter or wait for `--idle` seconds to end). Pages accumulate as per-page JPEGs in a timestamped staging dir. Exit codes: `0` success · `1` no scanner / device lost / jam · `2` no pages · `64` usage · `66` bad `--resume` dir · `130` interrupted. |
| `batch-file` | Validate, classify, rotate, merge, rename, and file the staged pages produced by `scan-batch`, driven by `<staging>/manifest.json`. Writes nothing unless every scanned page is accounted for exactly once; emits JSON sidecars and appends the global index. `--no-text-layer`, `--keep-staging`, `-o DIR`. Exit codes: `0` success · `1` validation failure · `2` assembly failure · `64` usage · `66` not a staging dir. |

### Paycheck workflow

**Mixed / unsorted stack** (the usual case):

```sh
scan-checks --staging                 # any order, orientation, or side
# A reader writes a manifest, one line per check:
#   <front_page> <back_page> <check_number> <YYYYMMDD> <front_rot> <back_rot>
checks-split <staging.pdf> <manifest> # → checksYYYYMMDD.pdf per paydate, each check normalized
```

**Single known paydate, pre-sorted stack:**

```sh
scan-checks 2026-06-05                # → checks20260605.pdf directly
checks-normalize checks20260605.pdf   # raw (never-split) scans still need this pass
```

The sort is physical: stack checks face up, lowest number on top, then flip the whole stack face-down into the feeder, top edge first (the iX500 feeds from the bottom).

### Mixed-batch workflow

```sh
scan-batch                            # feed in chunks; auto-resumes; Enter / idle ends it
# A reader classifies each page and writes <staging>/manifest.json
batch-file <staging-dir>              # validates, files each document, refuses on any gap
```

Output lands under `~/Documents/Scans/` in typed folders (`receipts/`, `invoices/`, `contracts/`, `statements/`, `letters/`, `taxes/`, `misc/`, `paychecks/`, `review/`), each PDF paired with a `.json` sidecar (OCR text, extracted fields, provenance). `entities.json` and `index.jsonl` track the entity registry and one line per filed document.

### GUI: NAPS2

`/Applications/NAPS2.app`. One-time profile: Profiles → New Profile → Driver **SANE** → device **ScanSnap iX500** → ADF Duplex, 300 dpi, Color → save as default. Then stack → Scan → Save PDF.

## Architecture

Each tool is a self-contained bash script (`set -euo pipefail`) that shells out to the CLI stack — nothing is imported or linked. Data flows in one direction:

```
paper → scanimage (SANE) → page images → img2pdf/qpdf → PDF
                                    ↘ (checks)  pdftoppm → magick normalize → qpdf assemble
                                    ↘ (batch)   staging dir → manifest.json (jq) → batch-file → typed folders + sidecars
```

- **Deterministic vs. judgement.** The bash tools do only deterministic work — acquisition, geometry, PDF assembly, validation, filing. Anything requiring reading a page (which paydate a check belongs to, what type a mixed-batch page is) is delegated to a reader that emits a **JSON manifest**; the tools never guess. `batch-file` and `checks-split` refuse to write unless the manifest fully accounts for every scanned page.
- **Guarded transforms.** `checks-normalize` only ever removes backing/edge fuzz, never content: trims run under multiple guards (border must read as gray backing, box sheet-sized, crop ≥15%, edge cleanup keeps ≥97% of both dimensions), and pages with nothing to trim pass through untouched — so re-runs are idempotent.
- **Device discovery.** The SANE device name embeds the scanner's serial; tools auto-discover it via `scanimage -L` on each run, so a changed serial only matters for hand-typed commands.
- **State on disk.** No database — filing state is the filesystem: typed folders, per-document `.json` sidecars, `entities.json`, and an append-only `index.jsonl`.

### Repo layout

```
bin/                        # the eight CLI tools (symlinked into ~/bin)
docs/                       # device-options.txt (full scanimage dump), superpowers/ plans & specs
test/                       # bats suites + stubs/ (fake scanimage) — scan-batch, batch-file, checks-normalize
ENVIRONMENT.md              # machine + scanner baseline recorded at preflight
PRD-ix500-mac-scanning.md   # original product requirements
TROUBLESHOOTING.md          # failure modes and fixes
```

## Status

In active use for document, paycheck, and mixed-batch scanning. The check workflow (scan → manifest → split → normalize → report) and the mixed-batch workflow (`scan-batch` + `batch-file`) both shipped 2026-06-11; per-check normalization inside `checks-split` and the entity registry landed 2026-06-12. Dev-only `bats` suites cover `batch-file` (24 tests), `scan-batch` (8), and `checks-normalize` (8) — run with `bats test/`. macOS + iX500 specific; validated on the single machine recorded in `ENVIRONMENT.md`.
