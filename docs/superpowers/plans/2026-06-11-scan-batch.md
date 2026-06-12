# scan-batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Continuous mixed-document scanning: a sensor-driven scan loop (`scan-batch`), Claude per-sheet bucket analysis with a user finalize gate, and a deterministic manifest-driven filing tool (`batch-file`) that routes paychecks through the existing checks pipeline.

**Architecture:** Three units mirroring the proven checks design — deterministic bash CLIs at the edges, Claude intelligence in the middle, a validated `manifest.json` as the contract. Spec: `docs/superpowers/specs/2026-06-11-scan-batch-design.md` (read it before starting).

**Tech Stack:** bash (`set -euo pipefail`, style of existing `bin/` tools), jq, scanimage (SANE fujitsu backend), img2pdf, jpegtran, qpdf, ImageMagick (`magick`, test fixtures only), poppler (`pdfinfo`, tests only), bats 1.13 for tests. **No bun/TypeScript here — this repo is plain bash.** All tools verified installed except `ocrmypdf` (intentionally optional; the code must skip it gracefully).

**Conventions:**
- Match the style of `bin/scan2pdf` / `bin/checks-split`: usage heredoc, long+short flags, explicit exit codes, `>&2` for errors, no backticks in commit messages.
- Run tests with: `bats test/` (or a single file: `bats test/scan-batch.bats`).
- Tests must never touch `~/Documents/Scans` — both new CLIs take `-o/--outdir` and tests always pass a temp dir.
- Commit at the end of each task exactly as written. **Never push** — `git push` is not part of this plan.

**File structure (locked in):**

| File | Responsibility |
|---|---|
| `bin/scan-batch` (create) | Continuous duplex scan loop → staging dir of page JPEGs + `batch.json` |
| `bin/batch-file` (create) | Validate `manifest.json`; rotate/merge/rename/file; sidecars + index; paycheck routing |
| `test/stubs/scanimage` (create) | File-driven scanimage stand-in for scan-batch tests |
| `test/scan-batch.bats` (create) | Loop behavior: chunks, numbering, sensor resume, idle end, resume, multifeed |
| `test/batch-file.bats` (create) | Validation refusals, filing, rotation, collisions, review, cleanup, paychecks, text layer |
| `~/.claude/skills/scan/SKILL.md` (modify) | New "Mixed batch workflow" section: analysis rules, buckets, finalize gate, manifest schema |
| `README.md` (modify) | New scan-batch section + repo layout entries |

---

### Task 1: `bin/scan-batch` — continuous scan loop

**Files:**
- Create: `test/stubs/scanimage`
- Create: `test/scan-batch.bats`
- Create: `bin/scan-batch`

- [ ] **Step 1: Write the scanimage stub**

Create `test/stubs/scanimage` (this is shared test infrastructure, written first because every scan-batch test depends on it):

```bash
#!/usr/bin/env bash
# Test stub for scanimage, driven by files in $SCANIMAGE_STUB_DIR:
#   devices   output for -L (file absent -> no scanner found)
#   sensor    yes/no, reported as the --page-loaded value in -A output
#   feed      one line per pending chunk: page count the next batch scan yields
# After serving a chunk the stub sets sensor to yes if feed lines remain, no
# otherwise — mimicking paper sitting in the ADF.
set -euo pipefail
dir="${SCANIMAGE_STUB_DIR:?SCANIMAGE_STUB_DIR not set}"

batch_pattern=""
batch_start=1
list=0
dump=0
for arg in "$@"; do
  case "$arg" in
    -L) list=1 ;;
    -A) dump=1 ;;
    --batch=*) batch_pattern="${arg#--batch=}" ;;
    --batch-start=*) batch_start="${arg#--batch-start=}" ;;
  esac
done

if (( list )); then
  [[ -f "$dir/devices" ]] && cat "$dir/devices"
  exit 0
fi

if (( dump )); then
  s=$(cat "$dir/sensor" 2>/dev/null || echo no)
  echo "    --page-loaded[=(yes|no)] [$s] [hardware]"
  exit 0
fi

if [[ -n "$batch_pattern" ]]; then
  count=0
  if [[ -s "$dir/feed" ]]; then
    count=$(head -1 "$dir/feed")
    tail -n +2 "$dir/feed" > "$dir/feed.tmp" && mv "$dir/feed.tmp" "$dir/feed"
  fi
  for (( i = 0; i < count; i++ )); do
    # shellcheck disable=SC2059
    printf -v f "$batch_pattern" "$(( batch_start + i ))"
    printf 'JPEGDATA' > "$f"
  done
  if [[ -s "$dir/feed" ]]; then echo yes > "$dir/sensor"; else echo no > "$dir/sensor"; fi
  echo "scanimage: Document feeder out of documents" >&2
  exit 7
fi
exit 0
```

Run: `chmod +x test/stubs/scanimage`

- [ ] **Step 2: Write the failing tests**

Create `test/scan-batch.bats`:

```bash
#!/usr/bin/env bats
# bin/scan-batch loop behavior, driven by test/stubs/scanimage.

setup() {
  TMP=$(mktemp -d)
  export SCANIMAGE_STUB_DIR="$TMP/stub"
  mkdir -p "$SCANIMAGE_STUB_DIR"
  export SCAN_BATCH_SCANIMAGE="$BATS_TEST_DIRNAME/stubs/scanimage"
  export SCAN_BATCH_POLL_SECS=1
  BATCHES="$TMP/batches"
  SCAN_BATCH="$BATS_TEST_DIRNAME/../bin/scan-batch"
  cat > "$SCANIMAGE_STUB_DIR/devices" <<'EOF'
device `fujitsu:ScanSnap iX500:1234' is a FUJITSU ScanSnap iX500 scanner
EOF
  echo no > "$SCANIMAGE_STUB_DIR/sensor"
}

teardown() { rm -rf "$TMP"; }

@test "exits 1 when no scanner is found" {
  rm "$SCANIMAGE_STUB_DIR/devices"
  run "$SCAN_BATCH" -o "$BATCHES" --idle 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no Fujitsu scanner"* ]]
}

@test "scans a single chunk and records batch.json" {
  echo 4 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run "$SCAN_BATCH" -o "$BATCHES" --idle 1
  [ "$status" -eq 0 ]
  staging=$(echo "$BATCHES"/batch-*)
  [ -f "$staging/pages/page-001.jpg" ]
  [ -f "$staging/pages/page-004.jpg" ]
  [ "$(jq -r '.pages' "$staging/batch.json")" = "4" ]
  [ "$(jq -c '.chunks' "$staging/batch.json")" = "[4]" ]
}

@test "auto-resumes when more paper lands, numbering continues" {
  printf '2\n2\n' > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run "$SCAN_BATCH" -o "$BATCHES" --idle 1
  [ "$status" -eq 0 ]
  staging=$(echo "$BATCHES"/batch-*)
  [ -f "$staging/pages/page-003.jpg" ]
  [ "$(jq -r '.pages' "$staging/batch.json")" = "4" ]
  [ "$(jq -c '.chunks' "$staging/batch.json")" = "[2,2]" ]
}

@test "exits 2 and removes the empty staging dir when nothing is scanned" {
  run "$SCAN_BATCH" -o "$BATCHES" --idle 1
  [ "$status" -eq 2 ]
  [ ! -d "$BATCHES"/batch-* ]
}

@test "warns about multifeed on odd duplex page count" {
  echo 3 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run "$SCAN_BATCH" -o "$BATCHES" --idle 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"odd page count"* ]]
}

@test "--resume continues numbering in an existing staging dir" {
  staging="$BATCHES/batch-20260611-000000"
  mkdir -p "$staging/pages"
  printf x > "$staging/pages/page-001.jpg"
  printf x > "$staging/pages/page-002.jpg"
  echo '{"started":"2026-06-11T00:00:00-0400"}' > "$staging/batch.json"
  echo 2 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run "$SCAN_BATCH" --resume "$staging" --idle 1
  [ "$status" -eq 0 ]
  [ -f "$staging/pages/page-003.jpg" ]
  [ "$(jq -r '.pages' "$staging/batch.json")" = "4" ]
  [ "$(jq -r '.started' "$staging/batch.json")" = "2026-06-11T00:00:00-0400" ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bats test/scan-batch.bats`
Expected: all 6 tests FAIL (`bin/scan-batch: No such file or directory` or similar).

- [ ] **Step 4: Write `bin/scan-batch`**

```bash
#!/usr/bin/env bash
# scan-batch — continuous duplex scan loop for mixed-document batches.
#
# Scans until the ADF empties, then watches the iX500's page-loaded sensor and
# resumes the moment more paper lands. Pages accumulate as per-page JPEGs in a
# staging dir for the batch workflow (Claude analysis -> batch-file).
#
# Part of the ix500-scan project (~/Arik/dev/office/scan-it).
set -euo pipefail

scanimage_bin="${SCAN_BATCH_SCANIMAGE:-scanimage}"
poll_secs="${SCAN_BATCH_POLL_SECS:-2}"

usage() {
  cat <<'EOF'
Usage: scan-batch [options]

Continuous batch scan from the iX500 ADF. Feed paper in any number of chunks;
scanning resumes automatically when the paper sensor sees a new stack.

End the batch by pressing Enter, or after --idle seconds with no paper.
Ctrl-C preserves the staging dir (continue later with --resume).

Options:
  --idle N             end the batch after N seconds with no paper (default: 60)
  -s, --simplex        front side only (default: duplex)
  -g, --gray           grayscale (default: color)
  -r, --resolution N   dpi (default: 300)
  -o, --outdir DIR     parent dir for batch staging dirs
                       (default: ~/Documents/Scans/.batches)
  --resume DIR         continue an interrupted batch staging dir
  -x, --scanopt ARG    extra option passed through to scanimage (repeatable)
  -h, --help           show this help

Exit codes:
  0 success (>=1 page)   1 no scanner found   2 no pages scanned
EOF
}

source_opt="ADF Duplex"
mode="Color"
resolution=300
idle=60
outparent="$HOME/Documents/Scans/.batches"
resume_dir=""
scanopts=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --idle)
      [[ $# -ge 2 ]] || { echo "scan-batch: $1 requires a value" >&2; exit 64; }
      idle="$2"; shift ;;
    -s|--simplex) source_opt="ADF Front" ;;
    -g|--gray) mode="Gray" ;;
    -r|--resolution)
      [[ $# -ge 2 ]] || { echo "scan-batch: $1 requires a value" >&2; exit 64; }
      resolution="$2"; shift ;;
    -o|--outdir)
      [[ $# -ge 2 ]] || { echo "scan-batch: $1 requires a value" >&2; exit 64; }
      outparent="$2"; shift ;;
    --resume)
      [[ $# -ge 2 ]] || { echo "scan-batch: $1 requires a value" >&2; exit 64; }
      resume_dir="$2"; shift ;;
    -x|--scanopt)
      [[ $# -ge 2 ]] || { echo "scan-batch: $1 requires a value" >&2; exit 64; }
      scanopts+=("$2"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "scan-batch: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "scan-batch: jq not found" >&2; exit 1; }
command -v "$scanimage_bin" >/dev/null 2>&1 \
  || { echo "scan-batch: '$scanimage_bin' not found" >&2; exit 1; }

discover_device() {
  "$scanimage_bin" -L 2>/dev/null | grep -i fujitsu | head -1 \
    | sed -e 's/^device `//' -e "s/' is a.*//" || true
}

device=$(discover_device)
if [[ -z "$device" ]]; then
  echo "scan-batch: no Fujitsu scanner found." >&2
  echo "  Check the lid is open (that powers it on) and USB is connected," >&2
  echo "  then run scan-diag for a full checkup." >&2
  exit 1
fi

if [[ -n "$resume_dir" ]]; then
  staging="${resume_dir%/}"
  [[ -d "$staging/pages" ]] || { echo "scan-batch: not a batch staging dir: $resume_dir" >&2; exit 66; }
  batch_id=$(basename "$staging")
  started=$(jq -r '.started // empty' "$staging/batch.json" 2>/dev/null || true)
else
  batch_id="batch-$(date +%Y%m%d-%H%M%S)"
  staging="$outparent/$batch_id"
  mkdir -p "$staging/pages"
  started=""
fi
[[ -n "$started" ]] || started=$(date +%Y-%m-%dT%H:%M:%S%z)

page_count() { find "$staging/pages" -name 'page-*.jpg' | wc -l | tr -d ' '; }

chunk_counts=""   # space-separated page count per chunk this run

write_batch_json() {
  local arr="[]"
  [[ -z "$chunk_counts" ]] || arr="[${chunk_counts// /,}]"
  jq -n --arg id "$batch_id" --arg started "$started" \
        --arg updated "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --arg source "$source_opt" --arg mode "$mode" \
        --argjson resolution "$resolution" \
        --argjson pages "$(page_count)" --argjson chunks "$arr" \
    '{batch: $id, started: $started, updated: $updated, source: $source,
      mode: $mode, resolution: $resolution, pages: $pages, chunks: $chunks}' \
    > "$staging/batch.json"
}

page_loaded() {
  "$scanimage_bin" -d "$device" -A 2>/dev/null \
    | grep -- '--page-loaded' | grep -q '\[yes\]'
}

# The iX500 has documented USB flakiness: if it drops off the bus, retry
# discovery with backoff, then bail preserving the staging dir.
ensure_device() {
  local tries=0 d
  while :; do
    d=$(discover_device)
    if [[ -n "$d" ]]; then device="$d"; return 0; fi
    tries=$((tries + 1))
    if (( tries >= 3 )); then
      write_batch_json
      echo "scan-batch: scanner disappeared mid-batch (USB?). Staging preserved." >&2
      echo "  Resume with: scan-batch --resume $staging" >&2
      exit 1
    fi
    sleep $(( tries * 2 ))
  done
}

scan_chunk() {
  local start=$(( $(page_count) + 1 ))
  # In --batch mode scanimage always ends with "Document feeder out of
  # documents" and nonzero status — the normal terminator, not an error.
  set +e
  "$scanimage_bin" -d "$device" --source "$source_opt" --mode "$mode" \
    --resolution "$resolution" --format=jpeg \
    --ald=yes --swdeskew=yes \
    ${scanopts[@]+"${scanopts[@]}"} \
    --batch="$staging/pages/page-%03d.jpg" --batch-start="$start" --progress
  set -e
}

on_interrupt() {
  write_batch_json
  echo ""
  echo "scan-batch: interrupted — staging preserved: $staging"
  echo "  Resume with: scan-batch --resume $staging"
  exit 130
}
trap on_interrupt INT

finish() {
  local total
  total=$(page_count)
  write_batch_json
  if (( total == 0 )); then
    [[ -n "$resume_dir" ]] || rm -rf "$staging"
    echo "scan-batch: no pages scanned — nothing staged." >&2
    exit 2
  fi
  if [[ "$source_opt" == "ADF Duplex" ]] && (( total % 2 != 0 )); then
    echo "scan-batch: WARNING — odd page count ($total) from a duplex batch;" >&2
    echo "  a multifeed (two sheets stuck together) is likely. Verify the pages." >&2
  fi
  echo "Batch complete: $total page(s)."
  echo "$staging"
  exit 0
}

# Block until paper lands (return 0) or the batch ends (Enter / idle timeout,
# which calls finish and never returns).
wait_for_paper() {
  local waited=0
  while (( waited < idle )); do
    if [[ -t 0 ]]; then
      # read doubles as the poll sleep and the Enter-to-end check.
      if read -r -s -t "$poll_secs"; then finish; fi
    else
      sleep "$poll_secs"
    fi
    waited=$(( waited + poll_secs ))
    if page_loaded; then return 0; fi
    ensure_device
  done
  finish
}

echo "Batch $batch_id ($source_opt, $mode, ${resolution}dpi)"
echo "Feed the ADF. Enter ends the batch; idle timeout ${idle}s."

while :; do
  if page_loaded; then
    before=$(page_count)
    scan_chunk
    after=$(page_count)
    if (( after > before )); then
      chunk_counts="${chunk_counts:+$chunk_counts }$((after - before))"
      echo "Chunk done: $((after - before)) page(s) — total $after."
      write_batch_json
    else
      # sensor said paper but the scan produced nothing — device trouble
      ensure_device
    fi
  else
    wait_for_paper
  fi
done
```

Run: `chmod +x bin/scan-batch`

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats test/scan-batch.bats`
Expected: 6 tests PASS (the suite takes ~15–20 s; each test waits out a 1 s idle timeout).

- [ ] **Step 6: Commit**

```bash
git add bin/scan-batch test/stubs/scanimage test/scan-batch.bats
git commit -m "Add scan-batch: continuous sensor-driven batch scanning with auto-resume"
```

---

### Task 2: `bin/batch-file` — validation, filing, sidecars, index, collisions, review, cleanup

Everything except paycheck routing (Task 3) and the ocrmypdf text layer (Task 4). The arg parser accepts the full final flag surface from the start (`--no-text-layer` and `--keep-staging` are parsed now, used in Tasks 4 and 2 respectively) so the CLI never changes shape.

**Files:**
- Create: `test/batch-file.bats`
- Create: `bin/batch-file`

- [ ] **Step 1: Write the failing tests**

Create `test/batch-file.bats`:

```bash
#!/usr/bin/env bats
# bin/batch-file: manifest validation and deterministic filing.

setup() {
  TMP=$(mktemp -d)
  OUT="$TMP/out"
  STAGING="$TMP/batch-20260611-120000"
  mkdir -p "$STAGING/pages"
  cat > "$STAGING/batch.json" <<'EOF'
{"batch":"batch-20260611-120000","started":"2026-06-11T12:00:00-0400","resolution":300}
EOF
  BATCH_FILE="$BATS_TEST_DIRNAME/../bin/batch-file"
}

teardown() { rm -rf "$TMP"; }

page() { # <filename> <label> [WxH]
  magick -size "${3:-600x800}" xc:white -pointsize 48 -fill black \
    -draw "text 40,100 '$2'" "$STAGING/pages/$1"
}

receipt_manifest() { # one receipt on page 1, blank back dropped
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "receipt", "name": "receipt-2026-06-08-home-depot-45.23",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ],
      "fields": { "vendor": "Home Depot", "date": "2026-06-08", "total": 45.23 },
      "text": [ "HOME DEPOT 45.23" ], "confidence": "high" }
  ],
  "dropped": [ { "file": "pages/page-002.jpg", "reason": "blank back" } ]
}
EOF
}

@test "files a receipt: PDF, sidecar, index line" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 0 ]
  pdf="$OUT/receipts/receipt-2026-06-08-home-depot-45.23.pdf"
  [ -f "$pdf" ]
  [ "$(qpdf --show-npages "$pdf")" = "1" ]
  side="$OUT/receipts/receipt-2026-06-08-home-depot-45.23.json"
  [ "$(jq -r '.fields.vendor' "$side")" = "Home Depot" ]
  [ "$(jq -r '.source.batch' "$side")" = "batch-20260611-120000" ]
  [ "$(jq -r '.text[0]' "$side")" = "HOME DEPOT 45.23" ]
  [ "$(wc -l < "$OUT/index.jsonl" | tr -d ' ')" = "1" ]
  [ "$(jq -r '.file' "$OUT/index.jsonl")" = "receipts/receipt-2026-06-08-home-depot-45.23.pdf" ]
}

@test "applies rotation so the page renders upright" {
  page page-001.jpg SIDEWAYS
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "misc", "name": "misc-2026-06-11-sideways",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 90 } ] }
  ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 0 ]
  # 600x800 px at 300 dpi = 144x192 pt; rotated 90 -> 192x144 pt (landscape).
  pdfinfo "$OUT/misc/misc-2026-06-11-sideways.pdf" | grep 'Page size' | grep -q '192 x 144'
}

@test "merges a multi-sheet invoice into one PDF" {
  page page-001.jpg "INVOICE p1"
  page page-002.jpg BLANK1
  page page-003.jpg "INVOICE p2"
  page page-004.jpg BLANK2
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "invoice", "name": "invoice-2026-05-31-coned-1042.50",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                 { "file": "pages/page-003.jpg", "rotate": 0 } ],
      "fields": { "vendor": "ConEd", "invoice_number": "9912", "amount": 1042.50 } }
  ],
  "dropped": [ { "file": "pages/page-002.jpg", "reason": "blank back" },
               { "file": "pages/page-004.jpg", "reason": "blank back" } ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 0 ]
  [ "$(qpdf --show-npages "$OUT/invoices/invoice-2026-05-31-coned-1042.50.pdf")" = "2" ]
}

@test "name collision gets a -2 suffix, never overwrites" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  mkdir -p "$OUT/receipts"
  printf existing > "$OUT/receipts/receipt-2026-06-08-home-depot-45.23.pdf"
  run "$BATCH_FILE" -o "$OUT" --no-text-layer --keep-staging "$STAGING"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/receipts/receipt-2026-06-08-home-depot-45.23.pdf")" = "existing" ]
  [ -f "$OUT/receipts/receipt-2026-06-08-home-depot-45.23-2.pdf" ]
  [ -f "$OUT/receipts/receipt-2026-06-08-home-depot-45.23-2.json" ]
}

@test "unaccounted page: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  page page-002.jpg ORPHAN
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "receipt", "name": "receipt-2026-06-08-x",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }
  ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "duplicate page reference: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "receipt", "name": "receipt-2026-06-08-a",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] },
    { "type": "receipt", "name": "receipt-2026-06-08-b",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }
  ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "bad rotation value: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "receipt", "name": "receipt-2026-06-08-x",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 45 } ] }
  ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "bad document name: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "receipt", "name": "../escape",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }
  ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "paycheck missing paydate: exit 1, nothing written" {
  page page-001.jpg CHECK
  page page-002.jpg BACK
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "paycheck",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                 { "file": "pages/page-002.jpg", "rotate": 0 } ],
      "fields": { "check_number": 1001 } }
  ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "review item files into review/ with reason sidecar; staging kept" {
  page page-001.jpg MYSTERY
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [],
  "review": [
    { "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ],
      "reason": "date unreadable", "guess": { "type": "receipt" } }
  ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 0 ]
  pdf="$OUT/review/review-batch-20260611-120000-01.pdf"
  [ -f "$pdf" ]
  [ "$(jq -r '.reason' "${pdf%.pdf}.json")" = "date unreadable" ]
  [ -d "$STAGING" ]
}

@test "staging removed on full success with no review items" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 0 ]
  [ ! -d "$STAGING" ]
}

@test "--keep-staging preserves staging on success" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  run "$BATCH_FILE" -o "$OUT" --no-text-layer --keep-staging "$STAGING"
  [ "$status" -eq 0 ]
  [ -d "$STAGING" ]
}
```

Note: the review test has an empty `documents` array; the implementation must allow `documents: []` when `review` is non-empty (the "no documents" check counts documents + review together).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/batch-file.bats`
Expected: all 12 tests FAIL (batch-file does not exist).

- [ ] **Step 3: Write `bin/batch-file`**

```bash
#!/usr/bin/env bash
# batch-file — deterministic filing step for a scan-batch staging dir.
#
# Reads <staging>/manifest.json (written by Claude during the batch workflow),
# validates it completely, then rotates, merges, renames, and files every
# document; writes JSON sidecars and appends the global index. Paycheck
# documents route through checks-split + checks-normalize unchanged.
#
# Part of the ix500-scan project (~/Arik/dev/office/scan-it).
set -euo pipefail

default_outdir="$HOME/Documents/Scans"

usage() {
  cat <<EOF
Usage: batch-file [options] <staging-dir>

Reads <staging-dir>/manifest.json and files every document. Writes NOTHING
unless the whole manifest validates (every scanned page accounted for exactly
once across documents, dropped, and review).

Options:
  -o, --outdir DIR    filing root (default: $default_outdir)
  --no-text-layer     skip the ocrmypdf searchable text layer
  --keep-staging      keep the staging dir even on full success
  -h, --help          show this help

Exit codes:
  0 success   1 validation failure (nothing written)   2 assembly failure
EOF
}

outdir="$default_outdir"
text_layer=1
keep_staging=0
staging=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--outdir)
      [[ $# -ge 2 ]] || { echo "batch-file: $1 requires a value" >&2; exit 64; }
      outdir="$2"; shift ;;
    --no-text-layer) text_layer=0 ;;
    --keep-staging) keep_staging=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "batch-file: unknown option: $1" >&2; usage >&2; exit 64 ;;
    *)
      [[ -z "$staging" ]] || { echo "batch-file: too many arguments" >&2; exit 64; }
      staging="$1" ;;
  esac
  shift
done

[[ -n "$staging" ]] || { usage >&2; exit 64; }
staging="${staging%/}"
[[ -d "$staging/pages" ]] || { echo "batch-file: not a batch staging dir: $staging" >&2; exit 66; }
manifest="$staging/manifest.json"
[[ -f "$manifest" ]] || { echo "batch-file: no manifest.json in $staging" >&2; exit 66; }

for tool in jq img2pdf jpegtran qpdf; do
  command -v "$tool" >/dev/null 2>&1 || { echo "batch-file: '$tool' not found" >&2; exit 1; }
done

fail() { echo "batch-file: $*" >&2; exit 1; }

jq -e . "$manifest" >/dev/null 2>&1 || fail "manifest.json is not valid JSON"

# ---------- validation: nothing is written past this section on failure ----------

jq -e '.batch | type == "string"' "$manifest" >/dev/null || fail "missing batch id"
jq -e '.documents | type == "array"' "$manifest" >/dev/null || fail "missing documents array"
jq -e '(.documents | length) + ((.review // []) | length) > 0' "$manifest" >/dev/null \
  || fail "manifest has no documents and no review items"
jq -e '.documents | all(.pages | type == "array" and length > 0)' "$manifest" >/dev/null \
  || fail "document with no pages"

# Rule 1: every staging page appears exactly once across documents/dropped/review.
referenced=$(jq -r '
  ([.documents[].pages[].file]
   + [(.dropped // [])[].file]
   + [(.review // [])[].pages[].file])[]' "$manifest" | sort)
actual=$(cd "$staging" && find pages -name 'page-*.jpg' | sort)
if [[ "$referenced" != "$actual" ]]; then
  echo "batch-file: page accounting mismatch — every scanned page must appear" >&2
  echo "  exactly once across documents/dropped/review:" >&2
  diff <(echo "$referenced") <(echo "$actual") | sed 's/^/  /' >&2 || true
  exit 1
fi

# Rule 2: rotations.
jq -e '([.documents[].pages[].rotate] + [(.review // [])[].pages[].rotate])
       | all(. == 0 or . == 90 or . == 180 or . == 270)' "$manifest" >/dev/null \
  || fail "bad rotate value (must be 0, 90, 180, or 270)"

# Rule 3: known types; safe slug names on every non-paycheck document.
jq -e '.documents
       | all(.type | IN("receipt","invoice","paycheck","contract","statement","letter","misc"))' \
  "$manifest" >/dev/null || fail "unknown document type"
jq -e '[.documents[] | select(.type != "paycheck")]
       | all(.name | type == "string" and test("^[a-z0-9][a-z0-9.-]*$"))' \
  "$manifest" >/dev/null || fail "bad or missing document name (lowercase slug required)"

# Rules 4+5: paychecks carry check_number + YYYYMMDD paydate, exactly front+back.
jq -e '[.documents[] | select(.type == "paycheck")]
       | all((.fields.check_number | tostring | test("^[0-9]+$"))
             and (.fields.paydate | tostring | test("^[0-9]{8}$"))
             and (.pages | length == 2))' "$manifest" >/dev/null \
  || fail "paycheck documents need numeric check_number, YYYYMMDD paydate, and exactly 2 pages"

# ---------- assembly ----------

batch_id=$(jq -r '.batch' "$manifest")
resolution=$(jq -r '.resolution // 300' "$staging/batch.json" 2>/dev/null || echo 300)
scanned_at=$(jq -r '.started // ""' "$staging/batch.json" 2>/dev/null || echo "")

workdir=$(mktemp -d -t batch-file)
trap 'rm -rf "$workdir"' EXIT

pp=0   # unique temp-name counter for prepared pages

prep_page() { # <src> <rotate> -> echoes path of an upright JPEG
  local src="$1" rot="$2" dest
  pp=$((pp + 1))
  dest="$workdir/p-$pp.jpg"
  if [[ "$rot" == "0" ]]; then
    cp "$src" "$dest"
  else
    # -trim drops edge blocks that are not MCU-aligned, keeping it lossless.
    jpegtran -rotate "$rot" -trim -copy none -outfile "$dest" "$src"
  fi
  echo "$dest"
}

build_pdf() { # <doc-json> <out.pdf> — assembles .pages[] in order
  local doc="$1" out="$2" imgs=() file rot
  while read -r file rot; do
    imgs+=("$(prep_page "$staging/$file" "$rot")")
  done < <(jq -r '.pages[] | "\(.file) \(.rotate)"' <<<"$doc")
  img2pdf --imgsize "${resolution}dpix${resolution}dpi" --output "$out" "${imgs[@]}"
}

folder_for() {
  case "$1" in
    receipt) echo receipts ;;
    invoice) echo invoices ;;
    contract) echo contracts ;;
    statement) echo statements ;;
    letter) echo letters ;;
    misc) echo misc ;;
  esac
}

unique_target() { # <dir> <base> -> echoes a .pdf path that does not exist yet
  local dir="$1" base="$2" n=2 t="$dir/$base.pdf"
  while [[ -e "$t" ]]; do t="$dir/$base-$n.pdf"; n=$((n + 1)); done
  echo "$t"
}

now() { date +%Y-%m-%dT%H:%M:%S%z; }

filed_count=0

file_document() { # <doc-json>
  local doc="$1" type folder name pdf rel
  type=$(jq -r '.type' <<<"$doc")
  folder=$(folder_for "$type")
  name=$(jq -r '.name' <<<"$doc")
  mkdir -p "$outdir/$folder"
  pdf=$(unique_target "$outdir/$folder" "$name")
  if ! build_pdf "$doc" "$pdf"; then
    echo "batch-file: assembly failed for $name" >&2
    return 1
  fi
  jq -n --argjson doc "$doc" --arg batch "$batch_id" --arg scanned "$scanned_at" \
    '{type: $doc.type, name: $doc.name, fields: ($doc.fields // {}),
      text: ($doc.text // []), confidence: ($doc.confidence // "high"),
      source: {batch: $batch, pages: [$doc.pages[].file], scanned: $scanned}}' \
    > "${pdf%.pdf}.json"
  rel="$folder/$(basename "$pdf")"
  jq -nc --arg file "$rel" --argjson doc "$doc" --arg batch "$batch_id" --arg filed "$(now)" \
    '{file: $file, type: $doc.type, fields: ($doc.fields // {}),
      batch: $batch, filed: $filed}' >> "$outdir/index.jsonl"
  filed_count=$((filed_count + 1))
  echo "  $rel"
}

mkdir -p "$outdir"
echo "Filing $batch_id into $outdir:"
while IFS= read -r doc; do
  file_document "$doc" || exit 2
done < <(jq -c '.documents[] | select(.type != "paycheck")' "$manifest")

# ---------- review items ----------

nrev=$(jq '(.review // []) | length' "$manifest")
for (( i = 0; i < nrev; i++ )); do
  item=$(jq -c ".review[$i]" "$manifest")
  mkdir -p "$outdir/review"
  base=$(printf 'review-%s-%02d' "$batch_id" "$((i + 1))")
  pdf=$(unique_target "$outdir/review" "$base")
  if ! build_pdf "$item" "$pdf"; then
    echo "batch-file: assembly failed for $(basename "$pdf")" >&2
    exit 2
  fi
  jq -n --argjson item "$item" --arg batch "$batch_id" \
    '{reason: ($item.reason // "unspecified"), guess: ($item.guess // {}),
      source: {batch: $batch, pages: [$item.pages[].file]}}' \
    > "${pdf%.pdf}.json"
  echo "  review/$(basename "$pdf")  ($(jq -r '.reason // "unspecified"' <<<"$item"))"
done

# ---------- cleanup + summary ----------

echo "Filed $filed_count document(s), $nrev held for review."
if (( keep_staging == 0 && nrev == 0 )); then
  rm -rf "$staging"
  echo "Staging removed."
else
  echo "Staging kept: $staging"
fi
```

Run: `chmod +x bin/batch-file`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/batch-file.bats`
Expected: 12 tests PASS. (The paycheck-missing-paydate test passes already because validation rules 4+5 are in place; routing itself is Task 3.)

- [ ] **Step 5: Commit**

```bash
git add bin/batch-file test/batch-file.bats
git commit -m "Add batch-file: validated manifest-driven filing with sidecars and index"
```

---

### Task 3: batch-file paycheck routing through checks-split + checks-normalize

**Files:**
- Modify: `bin/batch-file` (insert paycheck section between the regular filing loop and the review section)
- Modify: `test/batch-file.bats` (append one test)

- [ ] **Step 1: Write the failing test**

Append to `test/batch-file.bats`:

```bash
@test "paychecks route through checks-split and checks-normalize" {
  page page-001.jpg "CHECK 1002" 1200x500
  page page-002.jpg "BACK 1002" 1200x500
  page page-003.jpg "CHECK 1001" 1200x500
  page page-004.jpg "BACK 1001" 1200x500
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "paycheck",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                 { "file": "pages/page-002.jpg", "rotate": 0 } ],
      "fields": { "check_number": 1002, "paydate": "20260605",
                  "payee": "Jane Doe", "amount": 1234.56 } },
    { "type": "paycheck",
      "pages": [ { "file": "pages/page-003.jpg", "rotate": 0 },
                 { "file": "pages/page-004.jpg", "rotate": 0 } ],
      "fields": { "check_number": 1001, "paydate": "20260605",
                  "payee": "John Doe", "amount": 1100.00 } }
  ]
}
EOF
  # Stub checks-normalize: the real one re-renders at 300 dpi (slow, poppler);
  # routing is what we test here, so just record the invocation.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/checks-normalize" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${NORMALIZE_LOG:?}"
EOF
  chmod +x "$TMP/bin/checks-normalize"
  export NORMALIZE_LOG="$TMP/normalize.log"
  run env PATH="$TMP/bin:$BATS_TEST_DIRNAME/../bin:$PATH" NORMALIZE_LOG="$NORMALIZE_LOG" \
    "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 0 ]
  [ -f "$OUT/paychecks/checks20260605.pdf" ]
  [ "$(qpdf --show-npages "$OUT/paychecks/checks20260605.pdf")" = "4" ]
  grep -q "checks20260605.pdf" "$NORMALIZE_LOG"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/batch-file.bats`
Expected: 12 PASS, the new paycheck test FAILS (`checks20260605.pdf` not created — paycheck docs validate but are skipped by the filing loop).

- [ ] **Step 3: Insert the paycheck section**

In `bin/batch-file`, insert between the regular filing loop (after `done < <(jq -c '.documents[] | select(.type != "paycheck")' "$manifest")`) and the `# ---------- review items ----------` line:

```bash
# ---------- paychecks: reuse the existing checks pipeline ----------

npay=$(jq '[.documents[] | select(.type == "paycheck")] | length' "$manifest")
if (( npay > 0 )); then
  for tool in checks-split checks-normalize; do
    command -v "$tool" >/dev/null 2>&1 || { echo "batch-file: '$tool' not found" >&2; exit 1; }
  done
  # Build a temporary staging PDF of just the check pages (unrotated — the
  # checks manifest carries the rotations) plus a checks-split manifest whose
  # page numbers index into that PDF: front back number paydate frot brot.
  cmanifest="$workdir/checks-manifest"
  : > "$cmanifest"
  imgs=()
  p=0
  while IFS= read -r doc; do
    imgs+=("$staging/$(jq -r '.pages[0].file' <<<"$doc")")
    imgs+=("$staging/$(jq -r '.pages[1].file' <<<"$doc")")
    printf '%d %d %s %s %s %s\n' "$((p + 1))" "$((p + 2))" \
      "$(jq -r '.fields.check_number' <<<"$doc")" \
      "$(jq -r '.fields.paydate' <<<"$doc")" \
      "$(jq -r '.pages[0].rotate' <<<"$doc")" \
      "$(jq -r '.pages[1].rotate' <<<"$doc")" >> "$cmanifest"
    p=$((p + 2))
  done < <(jq -c '.documents[] | select(.type == "paycheck")' "$manifest")
  if ! img2pdf --imgsize "${resolution}dpix${resolution}dpi" \
       --output "$workdir/checks-staging.pdf" "${imgs[@]}"; then
    echo "batch-file: assembly failed for paycheck staging PDF" >&2
    exit 2
  fi
  checks-split -o "$outdir/paychecks" "$workdir/checks-staging.pdf" "$cmanifest"
  while IFS= read -r d; do
    checks-normalize "$outdir/paychecks/checks$d.pdf"
  done < <(jq -r '.documents[] | select(.type == "paycheck") | .fields.paydate' "$manifest" | sort -u)
fi
```

Then update the summary line near the end of the script. Replace:

```bash
echo "Filed $filed_count document(s), $nrev held for review."
```

with:

```bash
echo "Filed $filed_count document(s), $npay paycheck(s), $nrev held for review."
```

Note: `npay` is now defined before the summary in all paths because the paycheck section runs unconditionally (the `if` guards only the routing work, not the count).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/batch-file.bats`
Expected: 13 tests PASS. checks-split (the real one, found via the test's PATH) sorts by check number, so 1001 lands before 1002 inside `checks20260605.pdf`.

- [ ] **Step 5: Commit**

```bash
git add bin/batch-file test/batch-file.bats
git commit -m "batch-file: route paycheck documents through checks-split and checks-normalize"
```

---

### Task 4: batch-file searchable text layer (ocrmypdf, graceful when absent)

**Files:**
- Modify: `bin/batch-file`
- Modify: `test/batch-file.bats` (append one test)

- [ ] **Step 1: Write the failing test**

Append to `test/batch-file.bats`. The test builds a minimal PATH of symlinks to the required tools so ocrmypdf is guaranteed absent even if it gets installed on this machine later:

```bash
@test "missing ocrmypdf: prints skip notice, still succeeds" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  mkdir -p "$TMP/toolbin"
  for t in jq img2pdf jpegtran qpdf; do
    ln -s "$(command -v "$t")" "$TMP/toolbin/$t"
  done
  run env PATH="$TMP/toolbin:/usr/bin:/bin" "$BATCH_FILE" -o "$OUT" "$STAGING"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping searchable text layers"* ]]
  [ -f "$OUT/receipts/receipt-2026-06-08-home-depot-45.23.pdf" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/batch-file.bats`
Expected: 13 PASS, the new test FAILS (no skip notice is printed — there is no text-layer code yet).

- [ ] **Step 3: Implement the text layer**

In `bin/batch-file`, insert after the `unique_target()` function definition:

```bash
warned_ocr=0

add_text_layer() { # <pdf> — embed a searchable text layer in place
  (( text_layer )) || return 0
  if ! command -v ocrmypdf >/dev/null 2>&1; then
    if (( ! warned_ocr )); then
      echo "batch-file: ocrmypdf not installed — skipping searchable text layers"
      warned_ocr=1
    fi
    return 0
  fi
  if ocrmypdf --quiet "$1" "$1.ocr.pdf" 2>/dev/null; then
    mv "$1.ocr.pdf" "$1"
  else
    rm -f "$1.ocr.pdf"
    echo "batch-file: WARNING — ocrmypdf failed on $(basename "$1"); kept image-only PDF" >&2
  fi
}
```

Then in `file_document()`, insert a call right after the `build_pdf` if-block (immediately before the sidecar `jq -n` command):

```bash
  add_text_layer "$pdf"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/batch-file.bats`
Expected: 14 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/batch-file test/batch-file.bats
git commit -m "batch-file: optional ocrmypdf searchable text layer, skipped gracefully when absent"
```

---

### Task 5: scan skill — Mixed batch workflow section

**Files:**
- Modify: `~/.claude/skills/scan/SKILL.md` (append a new section at the end of the file)

No automated test — this is Claude-facing instruction text. Verification is the spec self-check in the final step.

- [ ] **Step 1: Append the workflow section**

Append to `~/.claude/skills/scan/SKILL.md`:

```markdown
## Mixed batch workflow (scan-batch → buckets → finalize → batch-file)

For a mixed pile — receipts, invoices, paychecks, contracts, statements, letters —
where the user wants everything OCR'd, named from metadata, and filed by type.
Full spec: ~/Arik/dev/office/scan-it/docs/superpowers/specs/2026-06-11-scan-batch-design.md

### 1. Scan

Run scan-batch in the background (it keeps scanning while the user feeds paper;
the paper sensor auto-resumes after each chunk; Enter or 60 s idle ends it):

    scan-batch

It prints the staging dir on completion: ~/Documents/Scans/.batches/batch-<ts>/
containing pages/page-NNN.jpg and batch.json. Duplex: sheet N = pages 2N-1 and 2N.
You may start analyzing completed pages while it still runs — they are just files.

### 2. Analyze each sheet into buckets

For every sheet, Read the front and back images and record into
<staging>/buckets.json (working file, your own format — one entry per sheet):

- rotation per side (0/90/180/270 clockwise) so content renders upright
- blank-back flag (typical for receipts)
- full OCR text per side (transcribe everything legible)
- type: receipt | invoice | paycheck | contract | statement | letter | misc
- fields by type:
  - receipt: vendor, date, total, payment method/last4
  - invoice: vendor, invoice_number, date, due_date, amount, "page M of N" hints
  - paycheck: check_number, paydate (YYYYMMDD), payee, amount
  - contract/statement/letter: party, date, title
- confidence: high | low (with the reason when low)

### 3. Present buckets and WAIT

Show a summary: counts per bucket and one identity line per sheet, e.g.
"sheet 3: receipt — Home Depot 2026-06-08 $45.23", flagging every low-confidence
item. The user may correct groupings ("sheets 5-6 are one invoice") or types.
**Do not finalize until the user explicitly says so.** This gate is the design;
never skip it.

### 4. Finalize: write manifest.json

On the user's signal, write <staging>/manifest.json:

    {
      "batch": "<staging dir basename>",
      "documents": [
        { "type": "receipt", "name": "receipt-2026-06-08-home-depot-45.23",
          "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ],
          "fields": { "vendor": "Home Depot", "date": "2026-06-08", "total": 45.23 },
          "text": [ "full OCR text per page, in page order" ],
          "confidence": "high" }
      ],
      "dropped": [ { "file": "pages/page-002.jpg", "reason": "blank back" } ],
      "review":  [ { "pages": [ { "file": "...", "rotate": 0 } ],
                     "reason": "date unreadable", "guess": { "type": "receipt" } } ]
    }

Rules batch-file enforces (it writes nothing on violation):
- every pages/page-*.jpg appears exactly once across documents/dropped/review
- rotate is 0/90/180/270; types from the list above
- non-paycheck documents need a name matching ^[a-z0-9][a-z0-9.-]*$
  (convention: <type>-<YYYY-MM-DD>-<slug>[-<amount>])
- paycheck documents: exactly 2 pages (front then back), numeric check_number,
  YYYYMMDD paydate — they route through checks-split/checks-normalize and land
  in paychecks/checksYYYYMMDD.pdf; do NOT give them a name
- multi-sheet documents: list pages in reading order; order paychecks any way
  (checks-split sorts by check number)
- anything you cannot classify or read confidently goes in review, never guessed

### 5. File

    batch-file <staging-dir>

Output lands in ~/Documents/Scans/<type folders>; sidecar .json per PDF; one
line per document appended to ~/Documents/Scans/index.jsonl. Review items land
in review/ with the reason. Staging is deleted on full success, kept if anything
went to review. Report the filing summary to the user, including review items.
```

- [ ] **Step 2: Verify the section against the validation rules in bin/batch-file**

Read the appended section and `bin/batch-file` side by side; confirm the rules listed in the skill match the jq validation checks exactly (types list, name regex, paycheck constraints, rotation values). Fix any drift in the skill text.

- [ ] **Step 3: Commit (skill file lives outside this repo — no git here)**

`~/.claude/skills/` is not a git repo in this project; nothing to commit. Note the change in the Task 6 commit message instead.

---

### Task 6: README, symlinks, full suite, acceptance

**Files:**
- Modify: `README.md` (insert a new section after the "## Paychecks: scan-checks + checks-split" section, and update the "## Repo layout" block)

- [ ] **Step 1: Add the README section**

Insert after the Paychecks section (before "## GUI: NAPS2"):

````markdown
## Mixed batches: scan-batch + batch-file

For a mixed pile (receipts, invoices, paychecks, contracts...) that should come out
as individually named, OCR'd, metadata-tagged PDFs filed by type:

```sh
scan-batch                  # feed paper in chunks; the paper sensor auto-resumes
                            # scanning; Enter (or 60s idle) ends the batch
# ...Claude reads each sheet, sorts them into buckets (receipts/invoices/
#    paychecks/...), shows you the summary, and WAITS for your "finalize".
#    Then it writes <staging>/manifest.json and runs:
batch-file <staging-dir>    # validates, rotates, merges, renames, files
```

Results land in `~/Documents/Scans/`: `receipts/`, `invoices/`, `contracts/`,
`statements/`, `letters/`, `misc/` — named like
`receipt-2026-06-08-home-depot-45.23.pdf`, each with a `.json` sidecar (full OCR
text + extracted fields + provenance) and a line in `index.jsonl`. Paychecks are
handed to checks-split/checks-normalize and land in `paychecks/checksYYYYMMDD.pdf`
exactly as the dedicated flow. Anything ambiguous goes to `review/` with the
reason — never silently guessed. batch-file refuses to write anything unless
every scanned page is accounted for exactly once.

Searchable text layers are embedded when `ocrmypdf` is installed
(`brew install ocrmypdf`, optional — filing works without it).
````

In the "## Repo layout" block, add after the `bin/checks-normalize` line:

```
bin/scan-batch          continuous batch scanning: sensor-driven auto-resume while you feed
bin/batch-file          manifest-driven filing: rotate/merge/rename, sidecars, index, review
```

and add after the `docs/device-options.txt` line:

```
test/                   bats suites for scan-batch and batch-file
```

- [ ] **Step 2: Symlink the new tools into ~/bin**

```bash
ln -sf "$PWD/bin/scan-batch" "$PWD/bin/batch-file" ~/bin/
ls -la ~/bin/scan-batch ~/bin/batch-file
```

Expected: both symlinks point into the repo's `bin/`.

- [ ] **Step 3: Run the full suite**

Run: `bats test/`
Expected: 20 tests PASS (6 scan-batch + 14 batch-file).

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/plans/2026-06-11-scan-batch.md docs/superpowers/specs/2026-06-11-scan-batch-design.md
git commit -m "Add mixed-batch workflow docs; scan skill gains batch analysis section"
```

- [ ] **Step 5: Hardware acceptance run (needs the physical scanner + a small mixed pile)**

This step needs the user at the scanner; coordinate with them:

1. Load a receipt, a two-page invoice, and two paychecks. Run `scan-batch` with no flags.
2. After the first chunk, drop one more sheet in — confirm scanning auto-resumes without a keypress.
3. Press Enter to end. Confirm the staging path prints and `batch.json` page count matches.
4. Run the Claude analysis per the scan skill: buckets presented, finalize gate honored.
5. Run `batch-file <staging>`: confirm filing, names, sidecars, an `index.jsonl` line per doc, and `paychecks/checks<paydate>.pdf` created/appended correctly.
6. Confirm staging was deleted (no review items) or kept (review items present).

Record any deviations as issues; do not patch live without a failing test first.

---

## Self-review checklist (run after writing, before handoff)

- Spec coverage: continuous loop + sensor resume (Task 1), per-sheet duplex capture (Task 1), validation rules 1–5 (Task 2), filing/sidecars/index/collisions/review/cleanup (Task 2), paycheck routing (Task 3), text layer (Task 4), bucket workflow + finalize gate (Task 5), README + acceptance (Task 6). Resume-after-USB-drop: implemented in Task 1 (`ensure_device`), tested indirectly via `--resume`.
- All code blocks complete; no TBDs.
- Cross-task consistency: `--no-text-layer`/`--keep-staging` parsed in Task 2, used in Tasks 2/4; `npay` defined in Task 3 before the summary it appears in; folder map matches the spec's explicit map (misc→`misc/`, not `miscs/`).
```
