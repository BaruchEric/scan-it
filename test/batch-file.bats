#!/usr/bin/env bats
# bin/batch-file: manifest validation and deterministic filing into the
# entity-first tree: <root>/<entity>/<type-folder>/[<YYYY>/]<name>.pdf

setup() {
  TMP=$(mktemp -d)
  OUT="$TMP/drive/scans"          # filing root; its parent is the Drive root
  DRIVE="$TMP/drive"
  STAGING="$TMP/batch-20260611-120000"
  mkdir -p "$STAGING/pages"
  cat > "$STAGING/batch.json" <<'EOF'
{"batch":"batch-20260611-120000","started":"2026-06-11T12:00:00-0400","resolution":300,
 "scanner":"ix500","user":"tester","host":"scanbox","default_entity":"rio-laundromat"}
EOF
  BATCH_FILE="$BATS_TEST_DIRNAME/../bin/batch-file"
}

teardown() { rm -rf "$TMP"; }

bf() { "$BATCH_FILE" -o "$OUT" --no-text-layer --no-dashboard "$@"; }

index_lines() { cat "$OUT"/_index/*.jsonl 2>/dev/null; }

page() { # <filename> <label> [WxH]
  magick -size "${3:-600x800}" xc:white \
    -font /System/Library/Fonts/Supplemental/Andale\ Mono.ttf \
    -pointsize 48 -fill black \
    -draw "text 40,100 '$2'" "$STAGING/pages/$1"
}

one_doc() { # <document-json> — a manifest holding one document on page 1
  cat > "$STAGING/manifest.json" <<EOF
{ "batch": "batch-20260611-120000", "documents": [ $1 ] }
EOF
}

receipt_manifest() { # one receipt on page 1, blank back dropped
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "receipt", "name": "receipt-2026-06-08-home-depot $45.23",
      "entity": "rio-laundromat",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ],
      "fields": { "vendor": "Home Depot", "date": "2026-06-08", "total": 45.23 },
      "text": [ "HOME DEPOT 45.23" ], "confidence": "high" }
  ],
  "dropped": [ { "file": "pages/page-002.jpg", "reason": "blank back" } ]
}
EOF
}

RECEIPT_REL='rio-laundromat/receipts/2026/receipt-2026-06-08-home-depot $45.23'

entities_registry() {
  mkdir -p "$OUT"
  cat > "$OUT/entities.json" <<'EOF'
{
  "entities": [
    { "slug": "personal", "name": "Personal", "kind": "personal",
      "copies": { "tax": "Baruch/Tax/{year}", "medical": "Baruch/Health/MedicalRecords" } },
    { "slug": "rio-laundromat", "name": "RIO LAUNDROMAT LLC", "kind": "business",
      "quickbooks": true,
      "copies": { "tax": "8328 De Soto Ave/Tax/{year}/Tax Supporting Docs" } },
    { "slug": "rio-cycles", "name": "RIO CYCLES LLC", "kind": "business" }
  ]
}
EOF
}

@test "files a receipt under entity/type/year with sidecar and index line" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  pdf="$OUT/$RECEIPT_REL.pdf"
  [ -f "$pdf" ]
  [ "$(qpdf --show-npages "$pdf")" = "1" ]
  side="$OUT/$RECEIPT_REL.json"
  [ "$(jq -r '.fields.vendor' "$side")" = "Home Depot" ]
  [ "$(jq -r '.entity' "$side")" = "rio-laundromat" ]
  [ "$(jq -r '.year' "$side")" = "2026" ]
  [ "$(jq -r '.date' "$side")" = "2026-06-08" ]
  [ "$(jq -r '.source.batch' "$side")" = "batch-20260611-120000" ]
  [ "$(jq -r '.source.scanner' "$side")" = "ix500" ]
  [ "$(jq -r '.source.user' "$side")" = "tester" ]
  [ "$(jq -r '.source.host' "$side")" = "scanbox" ]
  [ "$(jq -r '.text[0]' "$side")" = "HOME DEPOT 45.23" ]
  # Index: one file per user@filing-host, so two machines never append to one file.
  [ "$(ls "$OUT/_index")" = "tester@$(hostname -s).jsonl" ]
  [ "$(index_lines | wc -l | tr -d ' ')" = "1" ]
  [ "$(index_lines | jq -r '.file')" = "$RECEIPT_REL.pdf" ]
  [ "$(index_lines | jq -r '.scanner')" = "ix500" ]
}

@test "medical files under personal/medical (no year folder) with a vault follow-up" {
  page page-001.jpg LABS
  one_doc '{ "type": "medical", "name": "lab-results-timma-2026-06-01", "entity": "personal",
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ],
             "fields": { "provider": "Timma", "drawn": "2026-06-01" } }'
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  side="$OUT/personal/medical/lab-results-timma-2026-06-01.json"
  [ -f "${side%.json}.pdf" ]
  [ "$(jq -r '.followups.vault.status' "$side")" = "pending" ]
  [ "$(jq -r '.date' "$side")" = "2026-06-01" ]
}

@test "applies rotation so the page renders upright" {
  page page-001.jpg SIDEWAYS
  one_doc '{ "type": "misc", "name": "misc-2026-06-11-sideways", "entity": "personal",
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 90 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  # 600x800 px at 300 dpi = 144x192 pt; rotated 90 -> 192x144 pt (landscape).
  pdfinfo "$OUT/personal/misc/misc-2026-06-11-sideways.pdf" | grep 'Page size' | grep -q '192 x 144'
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
    { "type": "invoice", "name": "invoice-2026-05-31-coned $1,042.50", "entity": "rio-cycles",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                 { "file": "pages/page-003.jpg", "rotate": 0 } ],
      "fields": { "vendor": "ConEd", "invoice_number": "9912", "date": "2026-05-31", "amount": 1042.50 } }
  ],
  "dropped": [ { "file": "pages/page-002.jpg", "reason": "blank back" },
               { "file": "pages/page-004.jpg", "reason": "blank back" } ]
}
EOF
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  [ "$(qpdf --show-npages "$OUT/rio-cycles/invoices/2026/invoice-2026-05-31-coned \$1,042.50.pdf")" = "2" ]
}

@test "name collision gets a -2 suffix, never overwrites" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  mkdir -p "$(dirname "$OUT/$RECEIPT_REL")"
  printf existing > "$OUT/$RECEIPT_REL.pdf"
  run bf --keep-staging "$STAGING"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/$RECEIPT_REL.pdf")" = "existing" ]
  [ -f "$OUT/$RECEIPT_REL-2.pdf" ]
  [ -f "$OUT/$RECEIPT_REL-2.json" ]
}

@test "unaccounted page: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  page page-002.jpg ORPHAN
  one_doc '{ "type": "receipt", "name": "receipt-2026-06-08-x $1.00", "entity": "personal",
             "fields": { "date": "2026-06-08" },
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "duplicate page reference: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "receipt", "name": "receipt-2026-06-08-a $1.00", "entity": "personal",
      "fields": { "date": "2026-06-08" },
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] },
    { "type": "receipt", "name": "receipt-2026-06-08-b $2.00", "entity": "personal",
      "fields": { "date": "2026-06-08" },
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }
  ]
}
EOF
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "bad rotation value: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  one_doc '{ "type": "receipt", "name": "receipt-2026-06-08-x $1.00", "entity": "personal",
             "fields": { "date": "2026-06-08" },
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 45 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "bad document name: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  one_doc '{ "type": "receipt", "name": "../escape", "entity": "personal",
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "missing entity: exit 1, nothing written (the tree is entity first)" {
  page page-001.jpg LETTER
  one_doc '{ "type": "letter", "name": "letter-2026-06-01-x",
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [[ "$output" == *"every document needs an entity"* ]]
  [ ! -d "$OUT" ]
}

@test "receipt without a usable date: exit 1 (no year folder to pick)" {
  page page-001.jpg RECEIPT
  one_doc '{ "type": "receipt", "name": "receipt-x $1.00", "entity": "personal",
             "fields": { "date": "06/08/2026" },
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [[ "$output" == *"YYYY-MM-DD"* ]]
  [ ! -d "$OUT" ]
}

@test "paycheck missing paydate: exit 1, nothing written" {
  page page-001.jpg CHECK
  page page-002.jpg BACK
  one_doc '{ "type": "paycheck", "entity": "rio-laundromat",
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                        { "file": "pages/page-002.jpg", "rotate": 0 } ],
             "fields": { "check_number": 1001 } }'
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "review item files into _review/ with reason and source; staging kept" {
  page page-001.jpg MYSTERY
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [],
  "review": [
    { "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ],
      "reason": "date unreadable", "guess": { "type": "receipt", "entity": "personal" } }
  ]
}
EOF
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  pdf="$OUT/_review/review-batch-20260611-120000-01.pdf"
  [ -f "$pdf" ]
  [ "$(jq -r '.reason' "${pdf%.pdf}.json")" = "date unreadable" ]
  [ "$(jq -r '.source.user' "${pdf%.pdf}.json")" = "tester" ]
  [ -d "$STAGING" ]
  # The live dashboard reads .filed to stop offering File on this batch.
  [ -s "$STAGING/.filed" ]
}

@test "staging removed on full success with no review items" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  [ ! -d "$STAGING" ]
}

@test "--keep-staging preserves staging on success" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  run bf --keep-staging "$STAGING"
  [ "$status" -eq 0 ]
  [ -d "$STAGING" ]
}

@test "multi-page doc preserves each page (regression: temp-file collision)" {
  page page-001.jpg FIRST 600x800
  page page-002.jpg SECOND 800x600
  one_doc '{ "type": "misc", "name": "misc-2026-06-11-twopage", "entity": "personal",
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                        { "file": "pages/page-002.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  info=$(pdfinfo -f 1 -l 2 "$OUT/personal/misc/misc-2026-06-11-twopage.pdf")
  echo "$info" | grep 'Page    1' | grep -q '144 x 192'
  echo "$info" | grep 'Page    2' | grep -q '192 x 144'
}

@test "assembly failure: exit 2, no orphan PDF, no index line" {
  printf 'not a jpeg' > "$STAGING/pages/page-001.jpg"
  one_doc '{ "type": "misc", "name": "misc-2026-06-11-corrupt", "entity": "personal",
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 90 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 2 ]
  [ ! -e "$OUT/personal/misc/misc-2026-06-11-corrupt.pdf" ]
  [ ! -d "$OUT/_index" ]
  [ -d "$STAGING" ]
}

@test "unsafe batch id: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "../evil",
  "documents": [
    { "type": "receipt", "name": "receipt-2026-06-08-x $1.00", "entity": "personal",
      "fields": { "date": "2026-06-08" },
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }
  ]
}
EOF
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

stub_normalize() {
  # The real --page mode trims/deskews via magick (slow); routing is what we
  # test here, so record each invocation and emulate --page with a copy.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/checks-normalize" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${NORMALIZE_LOG:?}"
if [ "$1" = "--page" ]; then cp "$2" "$3"; fi
EOF
  chmod +x "$TMP/bin/checks-normalize"
  export NORMALIZE_LOG="$TMP/normalize.log"
}

bf_checks() { # batch-file with the stubbed normalizer and the repo's checks tools
  env PATH="$TMP/bin:$BATS_TEST_DIRNAME/../bin:$PATH" NORMALIZE_LOG="$NORMALIZE_LOG" \
    "$BATCH_FILE" -o "$OUT" --no-text-layer --no-dashboard "$@"
}

PAY_DIR_REL='rio-laundromat/paychecks/2026'

@test "paychecks route through checks-split into entity/paychecks/year with a sidecar and report" {
  page page-001.jpg "CHECK 1002" 1200x500
  page page-002.jpg "BACK 1002" 1200x500
  page page-003.jpg "CHECK 1001" 1200x500
  page page-004.jpg "BACK 1001" 1200x500
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "paycheck", "entity": "rio-laundromat",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                 { "file": "pages/page-002.jpg", "rotate": 0 } ],
      "fields": { "check_number": 1002, "paydate": "20260605",
                  "payee": "Jane Doe", "amount": 1234.56, "signed": true } },
    { "type": "paycheck", "entity": "rio-laundromat",
      "pages": [ { "file": "pages/page-003.jpg", "rotate": 0 },
                 { "file": "pages/page-004.jpg", "rotate": 0 } ],
      "fields": { "check_number": 1001, "paydate": "20260605",
                  "payee": "John Doe", "amount": 1100.00, "signed": "n" } }
  ]
}
EOF
  stub_normalize
  run bf_checks "$STAGING"
  [ "$status" -eq 0 ]
  pdf="$OUT/$PAY_DIR_REL/checks20260605.pdf"
  [ -f "$pdf" ]
  [ "$(qpdf --show-npages "$pdf")" = "4" ]
  # One --page invocation per check side (front, back, front, back), on
  # workdir images — normalized BEFORE filing; the filed target is never
  # reprocessed.
  [ "$(wc -l < "$NORMALIZE_LOG" | tr -d ' ')" = "4" ]
  [ "$(awk '$1 != "--page"' "$NORMALIZE_LOG" | wc -l | tr -d ' ')" = "0" ]
  [ "$(awk '{printf "%s ", $NF}' "$NORMALIZE_LOG")" = "front back front back " ]
  ! grep -q "$OUT/rio-laundromat" "$NORMALIZE_LOG"
  side="${pdf%.pdf}.json"
  [ "$(jq -r '.paydate' "$side")" = "2026-06-05" ]
  [ "$(jq -c '[.checks[].check_number]' "$side")" = "[1001,1002]" ]
  [ "$(jq -c '[.checks[].signed]' "$side")" = "[false,true]" ]
  [ "$(jq -r '.sources[0].scanner' "$side")" = "ix500" ]
  [ "$(jq -r '.followups.check_report.status' "$side")" = "done" ]
  report="$OUT/$PAY_DIR_REL/checks20260605-report.txt"
  grep -q '\$2,334.56' "$report"
  grep -q '1001' "$report"   # 1001 is the unsigned one
  [ "$(index_lines | wc -l | tr -d ' ')" = "2" ]
}

@test "second batch appends paychecks without re-normalizing filed pages" {
  page page-001.jpg "CHECK 1001" 1200x500
  page page-002.jpg "BACK 1001" 1200x500
  one_doc '{ "type": "paycheck", "entity": "rio-laundromat",
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                        { "file": "pages/page-002.jpg", "rotate": 0 } ],
             "fields": { "check_number": 1001, "paydate": "20260605" } }'
  stub_normalize
  run bf_checks "$STAGING"
  [ "$status" -eq 0 ]
  side="$OUT/$PAY_DIR_REL/checks20260605.json"
  # No amount/signed read yet, so the report waits.
  [ "$(jq -r '.followups.check_report.status' "$side")" = "pending" ]
  # Second batch, same paydate.
  S2="$TMP/batch-20260611-130000"
  mkdir -p "$S2/pages"
  cat > "$S2/batch.json" <<'EOF'
{"batch":"batch-20260611-130000","started":"2026-06-11T13:00:00-0400","resolution":300,
 "scanner":"brother","user":"ariel","host":"storemac"}
EOF
  STAGING="$S2" page page-001.jpg "CHECK 1002" 1200x500
  STAGING="$S2" page page-002.jpg "BACK 1002" 1200x500
  cat > "$S2/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-130000",
  "documents": [
    { "type": "paycheck", "entity": "rio-laundromat",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 },
                 { "file": "pages/page-002.jpg", "rotate": 0 } ],
      "fields": { "check_number": 1002, "paydate": "20260605" } }
  ]
}
EOF
  run bf_checks "$S2"
  [ "$status" -eq 0 ]
  [ "$(qpdf --show-npages "$OUT/$PAY_DIR_REL/checks20260605.pdf")" = "4" ]
  # Two --page calls per batch, each on that batch's NEW pages only — the
  # already-filed target is never re-rendered (no cumulative JPEG loss).
  [ "$(wc -l < "$NORMALIZE_LOG" | tr -d ' ')" = "4" ]
  [ "$(awk '$1 != "--page"' "$NORMALIZE_LOG" | wc -l | tr -d ' ')" = "0" ]
  ! grep -q "$OUT/$PAY_DIR_REL/checks20260605.pdf" "$NORMALIZE_LOG"
  [ "$(jq -c '[.checks[].check_number]' "$side")" = "[1001,1002]" ]
  [ "$(jq -c '[.sources[].user]' "$side")" = '["tester","ariel"]' ]
  # Each filer's index lines land in its own file.
  [ "$(ls "$OUT/_index" | wc -l | tr -d ' ')" = "2" ]
}

@test "unknown entity: exit 1, nothing written" {
  page page-001.jpg RECEIPT
  entities_registry
  one_doc '{ "type": "receipt", "name": "receipt-2026-06-08-x $1.00", "entity": "rio-cycle-typo",
             "fields": { "date": "2026-06-08" },
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown entity: rio-cycle-typo"* ]]
  [ ! -d "$OUT/rio-cycle-typo" ]
  [ ! -d "$OUT/_index" ]
}

@test "bad entity slug (uppercase): exit 1, even without a registry" {
  page page-001.jpg RECEIPT
  one_doc '{ "type": "receipt", "name": "receipt-2026-06-08-x $1.00", "entity": "RIO LAUNDROMAT LLC",
             "fields": { "date": "2026-06-08" },
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [ ! -d "$OUT" ]
}

@test "entity accepted without a registry (slug check only)" {
  page page-001.jpg RECEIPT
  one_doc '{ "type": "receipt", "name": "receipt-2026-06-08-x $1.00", "entity": "acme",
             "fields": { "date": "2026-06-08" },
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  [ -f "$OUT/acme/receipts/2026/receipt-2026-06-08-x \$1.00.pdf" ]
}

@test "unsafe copies path in the registry: exit 1, nothing written" {
  page page-001.jpg TAX
  mkdir -p "$OUT"
  echo '{"entities":[{"slug":"personal","copies":{"tax":"../outside"}}]}' > "$OUT/entities.json"
  one_doc '{ "type": "tax", "name": "tax-2025-w2-acme", "entity": "personal",
             "fields": { "tax_year": 2025 },
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 1 ]
  [[ "$output" == *"copies"* ]]
  [ ! -d "$OUT/personal" ]
}

@test "tax files under the tax year and is copied to the entity's Drive Tax folder" {
  page page-001.jpg W2
  entities_registry
  one_doc '{ "type": "tax", "name": "tax-2025-w2-adp", "entity": "rio-laundromat",
             "fields": { "party": "ADP", "date": "2026-01-28", "tax_year": 2025, "title": "W-2" },
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  side="$OUT/rio-laundromat/taxes/2025/tax-2025-w2-adp.json"
  [ -f "${side%.json}.pdf" ]
  copy="$DRIVE/8328 De Soto Ave/Tax/2025/Tax Supporting Docs/tax-2025-w2-adp.pdf"
  [ -f "$copy" ]
  [ "$(jq -r '.followups.copy.status' "$side")" = "done" ]
  [ "$(jq -r '.followups.copy.ref' "$side")" = "8328 De Soto Ave/Tax/2025/Tax Supporting Docs/tax-2025-w2-adp.pdf" ]
  [ "$(jq -r '.copies[0]' "$side")" = "8328 De Soto Ave/Tax/2025/Tax Supporting Docs/tax-2025-w2-adp.pdf" ]
  [ "$(index_lines | jq -r '.type')" = "tax" ]
}

@test "existing file in the copy target is never overwritten" {
  page page-001.jpg LABS
  entities_registry
  mkdir -p "$DRIVE/Baruch/Health/MedicalRecords"
  printf keep > "$DRIVE/Baruch/Health/MedicalRecords/lab-results-quest-2026-06-01.pdf"
  one_doc '{ "type": "medical", "name": "lab-results-quest-2026-06-01", "entity": "personal",
             "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ] }'
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  [ "$(cat "$DRIVE/Baruch/Health/MedicalRecords/lab-results-quest-2026-06-01.pdf")" = "keep" ]
  [ -f "$DRIVE/Baruch/Health/MedicalRecords/lab-results-quest-2026-06-01-2.pdf" ]
}

@test "follow-ups: QuickBooks only for entities that keep books there; calendar on a due date" {
  page page-001.jpg INV1
  page page-002.jpg INV2
  entities_registry
  cat > "$STAGING/manifest.json" <<'EOF'
{
  "batch": "batch-20260611-120000",
  "documents": [
    { "type": "invoice", "name": "invoice-2026-06-01-ladwp $310.00", "entity": "rio-laundromat",
      "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ],
      "fields": { "vendor": "LADWP", "date": "2026-06-01", "due_date": "2026-06-21", "amount": 310 } },
    { "type": "invoice", "name": "invoice-2026-06-02-sce $99.00", "entity": "rio-cycles",
      "pages": [ { "file": "pages/page-002.jpg", "rotate": 0 } ],
      "fields": { "vendor": "SCE", "date": "2026-06-02" } }
  ]
}
EOF
  run bf "$STAGING"
  [ "$status" -eq 0 ]
  a="$OUT/rio-laundromat/invoices/2026/invoice-2026-06-01-ladwp \$310.00.json"
  b="$OUT/rio-cycles/invoices/2026/invoice-2026-06-02-sce \$99.00.json"
  [ "$(jq -c '.followups | keys' "$a")" = '["calendar","quickbooks"]' ]
  [ "$(jq -c '.followups | keys' "$b")" = '[]' ]
}

@test "missing ocrmypdf: prints skip notice, still succeeds" {
  page page-001.jpg RECEIPT
  page page-002.jpg BLANK
  receipt_manifest
  # Every tool on PATH but ocrmypdf: on Linux it shares /usr/bin with the rest.
  mkdir -p "$TMP/toolbin"
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    for f in "$d"/*; do
      n=${f##*/}
      [[ -x "$f" && "$n" != ocrmypdf && ! -e "$TMP/toolbin/$n" ]] && ln -s "$f" "$TMP/toolbin/$n"
    done
  done
  run env PATH="$TMP/toolbin" "$BATCH_FILE" -o "$OUT" "$STAGING"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping searchable text layers"* ]]
  [ -f "$OUT/$RECEIPT_REL.pdf" ]
}
