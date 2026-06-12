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
