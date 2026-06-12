# scan-batch — continuous mixed-document scanning with Claude-driven filing

**Date:** 2026-06-11
**Status:** Approved design, pre-implementation
**Repo:** ~/Arik/dev/office/scan-it

## Problem

Today the stack handles two shapes of work: `scan2pdf` (whole stack → one dated PDF,
no intelligence) and the paycheck pipeline (`scan-checks` → Claude manifest →
`checks-split`, which normalizes each check; checks only). There is no flow for a **mixed pile**
— receipts, invoices, paychecks, contracts, statements — where the user wants to feed
paper continuously and end up with individually named, OCR'd, metadata-rich documents
filed by type.

## Goals

1. Scan non-stop while the user feeds paper: when the ADF empties, resume automatically
   the moment more paper lands (hardware `--page-loaded` sensor), no keypress needed.
2. Capture every sheet duplex as individual page images.
3. Claude analyzes **each sheet (front+back) individually**: uniform orientation, blank-back
   detection, full OCR, document type, type-specific metadata fields.
4. Sheets land in **buckets** by type; the user reviews the bucket summary and gives an
   explicit **finalize signal** before anything is merged, renamed, or filed.
5. On finalize: merge multi-sheet logical documents (invoices, contracts), order paychecks,
   smart-rename from metadata, file into type folders, write sidecars and a global index.
6. Detected paychecks route through the **existing** checks pipeline unchanged, landing as
   `checksYYYYMMDD.pdf` exactly as today.

## Non-goals

- WiFi scanning (impossible on iX500/SANE — see README), non-iX500 scanners, any GUI.
- Watching folders / processing already-digital documents.
- Cloud upload or auto-commit of scanned output.
- Replacing `scan2pdf` or `scan-checks` — they remain the right tools for their cases.

## Architecture

Three units, mirroring the proven checks design (deterministic tools at the edges,
Claude intelligence in the middle, a validated manifest as the contract):

| Unit | Kind | Single purpose |
|---|---|---|
| `bin/scan-batch` | bash CLI | Continuous duplex scan loop → staging dir of page images |
| Claude analysis | `scan` skill workflow | Per-sheet OCR/classify → buckets → **user gate** → `manifest.json` |
| `bin/batch-file` | bash CLI | Validate manifest; rotate, merge, rename, file; sidecars + index |

### Flow

```
scan-batch ──→ .batches/batch-<ts>/pages/page-NNN.jpg + batch.json
                      │
Claude reads sheets ──→ buckets.json (working file) ──→ bucket summary to user
                      │                                      │
                      │                      user corrects, then says "finalize"
                      ▼                                      │
              manifest.json  ◄───────────────────────────────┘
                      │
batch-file ──→ ~/Documents/Scans/<type>/<name>.pdf + <name>.json
            ──→ index.jsonl append
            ──→ paycheck pages → checks-split (per-check normalize) → checksYYYYMMDD.pdf
            ──→ doubts → ~/Documents/Scans/review/
```

## Unit 1: `bin/scan-batch`

Continuous-scan CLI in the style of the existing `bin/` tools (bash, `set -euo pipefail`).

**Usage:** `scan-batch [options]`

| Option | Default | Meaning |
|---|---|---|
| `--idle N` | 60 | seconds with no paper before the batch auto-ends |
| `-s, --simplex` | duplex | front side only |
| `-g, --gray` | color | grayscale |
| `-r, --resolution N` | 300 | dpi |
| `--resume DIR` | — | continue an interrupted batch (numbering continues) |
| `-x, --scanopt ARG` | — | passthrough to scanimage (repeatable) |

**Behavior:**

- Scan params: duplex, color, 300 dpi, `--ald --swdeskew`, JPEG output (same rationale
  as scan-checks: trimmed page heights, driver deskew).
- Staging: `~/Documents/Scans/.batches/batch-YYYYMMDD-HHMMSS/pages/page-%03d.jpg`.
- Loop: run `scanimage --batch` until the feeder empties (the normal terminator, per
  scan2pdf); then poll the `--page-loaded` hardware sensor every 2 s. Paper detected →
  restart `scanimage` with `--batch-start=<next page number>`. The loop also handles
  starting with an empty ADF (waits for the first sheet).
- Ending the batch: **Enter** in the terminal at any wait point, or `--idle` seconds with
  no paper. Ctrl-C preserves staging (resumable).
- Writes `batch.json` in the staging dir: batch id, start/end timestamps, scan params,
  final page count, chunk boundaries.
- Duplex invariant: sheet N = pages 2N−1 and 2N. An odd final page count prints a
  multifeed warning (two sheets stuck together), same as scan-checks.
- Device discovery identical to scan2pdf (`scanimage -L`, grep fujitsu). If the scanner
  vanishes mid-batch (documented USB-3/hub flakiness): retry discovery 3× with backoff,
  then exit preserving staging and print the `--resume` command.
- Exit codes: 0 = success (≥1 page), 1 = no scanner, 2 = no pages scanned.

## Unit 2: Claude analysis (scan skill workflow)

Added as a workflow section to the existing `scan` skill. Claude may begin analyzing
completed pages while scan-batch is still running (they are just files), but the
**finalize step never runs without the user's explicit signal**.

**Per sheet** (front image + back image), Claude records into `buckets.json` in the
staging dir:

- rotation needed per side (0/90/180/270) so content renders upright,
- blank-back flag (typical for receipts),
- full OCR text per side,
- bucket/type: `receipt` · `invoice` · `paycheck` · `contract` · `statement` · `letter` · `misc`,
- type-specific fields:
  - receipt: vendor, date, total, payment method/last4
  - invoice: vendor, invoice number, date, due date, amount, "page M of N" hints
  - paycheck: check number, paydate, payee, amount
  - contract / statement / letter: party/sender, date, title/subject
- confidence: `high` | `low` with a reason when low.

**Bucket review:** Claude presents a summary — counts per bucket, one identity line per
sheet (e.g. `sheet 3: receipt — Home Depot 2026-06-08 $45.23`), and all low-confidence
flags. The user corrects assignments and groupings in conversation
("sheets 5–6 are one invoice", "sheet 9 is a statement"), then says **finalize**.

**On finalize**, Claude writes `manifest.json` (schema below): multi-sheet documents
merged in page order, paychecks ordered by check number within paydate, names generated
per the naming convention, unresolved doubts assigned to `review`.

## Manifest contract (`manifest.json`)

The validated interface between Claude and `batch-file` — analogous to the
checks-split manifest.

```json
{
  "batch": "batch-20260611-213000",
  "documents": [
    {
      "type": "receipt",
      "name": "receipt-2026-06-08-home-depot$45.23",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ],
      "fields": { "vendor": "Home Depot", "date": "2026-06-08", "total": 45.23 },
      "text": [ "full OCR text of page 1" ],
      "confidence": "high"
    },
    {
      "type": "paycheck",
      "pages": [ { "file": "pages/page-005.jpg", "rotate": 0 },
                 { "file": "pages/page-006.jpg", "rotate": 180 } ],
      "fields": { "check_number": 1042, "paydate": "20260605",
                  "payee": "Jane Doe", "amount": 1234.56 },
      "text": [ "front text", "back text" ]
    }
  ],
  "dropped": [ { "file": "pages/page-002.jpg", "reason": "blank back" } ],
  "review":  [ { "pages": [ { "file": "pages/page-009.jpg", "rotate": 90 } ],
                 "reason": "date unreadable", "guess": { "type": "receipt" } } ]
}
```

**Validation rules (batch-file refuses to write anything on violation):**

1. Every `page-*.jpg` in the staging dir appears **exactly once** across
   `documents[].pages`, `dropped[]`, and `review[]` — no missing, no duplicate pages.
2. `rotate` ∈ {0, 90, 180, 270}.
3. `type` ∈ the known set; `name` matches `^[a-z0-9][a-z0-9.$-]*$` (no path separators).
4. Paycheck documents must carry `check_number` and `paydate` (checks-split needs them).
5. Within a paycheck document, pages are exactly one front + one back.

## Unit 3: `bin/batch-file`

**Usage:** `batch-file <staging-dir> [--no-text-layer] [--keep-staging]`
(reads `<staging-dir>/manifest.json`)

Deterministic filing, in dependency-light bash like checks-split (jpegtran, img2pdf,
qpdf, optional ocrmypdf):

1. **Validate** the manifest fully before writing anything (rules above).
2. Per non-paycheck document: lossless-rotate JPEGs (`jpegtran -rotate`), assemble with
   `img2pdf --imgsize 300dpix300dpi`, then add a searchable text layer with `ocrmypdf`
   (default on when installed; `--no-text-layer` or missing ocrmypdf → skip with a notice).
3. **File:** `~/Documents/Scans/<folder>/<name>.pdf`, with an explicit type→folder map:
   receipt→`receipts/`, invoice→`invoices/`, contract→`contracts/`,
   statement→`statements/`, letter→`letters/`, misc→`misc/` (paychecks route via
   step 6; review items via step 7 to `review/`). Name collisions get
   `-2`, `-3` suffixes (never overwrite).
4. **Sidecar** `<name>.json` next to each PDF: type, fields, full per-page OCR text,
   provenance (batch id, source page numbers, scan timestamp), confidence.
5. **Index:** append one JSON line per filed document to `~/Documents/Scans/index.jsonl`
   (file path, type, fields, batch, filed-at). Full text lives only in sidecars.
6. **Paychecks:** collect all paycheck documents; build a temporary staging PDF of just
   those pages (img2pdf, in manifest order); generate a checks-split manifest
   (`<front> <back> <check_number> <paydate> <front_rot> <back_rot>` against that PDF);
   run `checks-split` — it normalizes each check's pages itself, so no separate
   normalize pass follows. Appending to existing paydate PDFs is handled by checks-split
   as today.
7. **Review items:** rotate + assemble like normal docs, file into `review/` named
   `review-<batch>-<nn>.pdf` with a sidecar containing the reason and Claude's guess.
8. **Cleanup:** on full success with an empty `review[]`, delete the staging dir; if
   anything went to review (or `--keep-staging`), keep staging so originals remain
   re-processable.
9. Exit codes: 0 = success, 1 = validation failure (nothing written), 2 = assembly
   failure (partial output reported, staging kept).

## Naming convention

`<type>-<YYYY-MM-DD>-<slug>[$<amount>]` — lowercase, hyphen-separated, with the
amount (when present) joined by a literal `$`, e.g.
`receipt-2026-06-08-home-depot$45.23.pdf`,
`invoice-2026-05-31-coned$1042.50.pdf`,
`contract-2026-04-12-acme-lease.pdf`.
Paychecks keep the existing `checksYYYYMMDD.pdf` convention.

## Error handling summary

| Failure | Behavior |
|---|---|
| Scanner vanishes mid-batch | retry discovery 3×, exit preserving staging, print `--resume` hint |
| Odd page count in duplex | multifeed warning printed; user can rescan the stuck sheets into the same batch |
| Invalid manifest | batch-file writes nothing, exit 1 with the specific violation |
| Low-confidence analysis | goes to `review/`, never silently guessed |
| Name collision | `-2`/`-3` suffix, never overwrite |
| ocrmypdf missing | text layer skipped with a notice; filing proceeds |

## Testing

- **batch-file (primary surface):** fixture staging dirs with generated images +
  manifests in `test/`. Assert: page counts and rotations in output PDFs, sidecar
  contents, index lines, collision suffixing, review routing, paycheck handoff
  (checks-split invoked with the right manifest), and that every invalid-manifest
  fixture writes zero files.
- **scan-batch:** loop logic honors a `SCAN_BATCH_SCANIMAGE` env override pointing at a
  stub script, enabling tests for chunk numbering (`--batch-start`), idle timeout,
  Enter-to-end, and `--resume`.
- **Acceptance:** one real end-to-end run with a small mixed pile (a receipt, a
  two-page invoice, two paychecks) verifying filing, naming, sidecars, index, and
  `checksYYYYMMDD.pdf` append.

## Deliverables

1. `bin/scan-batch` (new)
2. `bin/batch-file` (new)
3. `scan` skill update: batch workflow (analysis rules, bucket review, finalize gate)
4. README section + repo-layout update
5. Tests per above
