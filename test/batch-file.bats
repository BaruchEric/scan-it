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
  magick -size "${3:-600x800}" xc:white \
    -font /System/Library/Fonts/Supplemental/Andale\ Mono.ttf \
    -pointsize 48 -fill black \
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

@test "multi-page doc preserves each page (regression: temp-file collision)" {
  page page-001.jpg FIRST 600x800
  page page-002.jpg SECOND 800x600
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "misc", "name": "misc-2026-06-11-twopage",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                 { "file": "pages/page-002.jpg", "rotate": 0 } ] }
  ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 0 ]
  info=$(pdfinfo -f 1 -l 2 "$OUT/misc/misc-2026-06-11-twopage.pdf")
  echo "$info" | grep 'Page    1' | grep -q '144 x 192'
  echo "$info" | grep 'Page    2' | grep -q '192 x 144'
}

@test "assembly failure: exit 2, no orphan PDF, no index line" {
  printf 'not a jpeg' > "$STAGING/pages/page-001.jpg"
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "misc", "name": "misc-2026-06-11-corrupt",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 90 } ] }
  ]
}
EOF
  run "$BATCH_FILE" -o "$OUT" --no-text-layer "$STAGING"
  [ "$status" -eq 2 ]
  [ ! -e "$OUT/misc/misc-2026-06-11-corrupt.pdf" ]
  [ ! -e "$OUT/index.jsonl" ]
  [ -d "$STAGING" ]
}

@test "unsafe batch id: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "../evil",
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
