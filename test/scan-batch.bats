#!/usr/bin/env bats
# bin/scan-batch loop behavior, driven by test/stubs/scanimage.

setup() {
  TMP=$(mktemp -d)
  export SCANIMAGE_STUB_DIR="$TMP/stub"
  mkdir -p "$SCANIMAGE_STUB_DIR"
  export SCAN_BATCH_SCANIMAGE="$BATS_TEST_DIRNAME/stubs/scanimage"
  export SCAN_BATCH_POLL_SECS=1
  # Pin to the stubbed iX500 path so a live Brother on the tester's desk is
  # never touched.
  export SCAN_SCANNER=ix500
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
  [[ "$output" == *"no scanner found"* ]]
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
  # Ended by the idle timeout: the feeder was empty at the last look.
  [ "$(jq -r '.ended' "$staging/batch.json")" = "idle" ]
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

@test "rejects non-integer --idle at parse time" {
  run "$SCAN_BATCH" -o "$BATCHES" --idle abc
  [ "$status" -eq 64 ]
  [[ "$output" == *"requires an integer"* ]]
}

@test "bails out after repeated zero-page scans (jam) instead of spinning" {
  printf '0\n0\n0\n0\n0\n' > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run "$SCAN_BATCH" -o "$BATCHES" --idle 30
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing feeding"* ]]
  [ "$(jq -r '.ended' "$BATCHES"/batch-*/batch.json)" = "jam" ]
}

@test "records scanner, user, host and the profile's default entity in batch.json" {
  root="$TMP/root"
  mkdir -p "$root"
  cat > "$root/profiles.json" <<'JSON'
{
  "users": [ { "slug": "ariel", "name": "Ariel", "accounts": ["nobody-matches"] } ],
  "profiles": [
    { "user": "ariel", "scanner": "ix500", "default_entity": "rio-laundromat" },
    { "user": "*", "scanner": "*", "default_entity": "personal" }
  ]
}
JSON
  echo 2 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run env SCAN_ROOT="$root" "$SCAN_BATCH" -o "$BATCHES" --idle 1 --user ariel
  [ "$status" -eq 0 ]
  staging=$(echo "$BATCHES"/batch-*)
  [ "$(jq -r '.scanner' "$staging/batch.json")" = "ix500" ]
  [ "$(jq -r '.user' "$staging/batch.json")" = "ariel" ]
  [ "$(jq -r '.host' "$staging/batch.json")" = "$(hostname -s)" ]
  [ "$(jq -r '.default_entity' "$staging/batch.json")" = "rio-laundromat" ]
}

@test "user comes from a profiles.json account match; wildcard profile supplies the entity" {
  root="$TMP/root"
  mkdir -p "$root"
  cat > "$root/profiles.json" <<JSON
{
  "users": [ { "slug": "elsa", "accounts": ["$USER"] } ],
  "profiles": [ { "user": "*", "scanner": "*", "default_entity": "personal" } ]
}
JSON
  echo 2 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run env -u SCAN_USER SCAN_ROOT="$root" "$SCAN_BATCH" -o "$BATCHES" --idle 1
  [ "$status" -eq 0 ]
  staging=$(echo "$BATCHES"/batch-*)
  [ "$(jq -r '.user' "$staging/batch.json")" = "elsa" ]
  [ "$(jq -r '.default_entity' "$staging/batch.json")" = "personal" ]
}

@test "staging defaults to SCAN_STAGING, never the Drive filing root" {
  echo 2 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run env SCAN_STAGING="$TMP/local" SCAN_ROOT="$TMP/drive" "$SCAN_BATCH" --idle 1
  [ "$status" -eq 0 ]
  [ -d "$(echo "$TMP"/local/batch-*)" ]
  [ ! -e "$TMP/drive" ]
}

@test "rejects a non-slug --user" {
  run "$SCAN_BATCH" -o "$BATCHES" --idle 1 --user "Ariel B"
  [ "$status" -eq 64 ]
}

@test "a .stop file ends the batch at the next poll, and .pid marks it while it runs" {
  "$SCAN_BATCH" -o "$BATCHES" --idle 60 > "$TMP/out" 2>&1 &
  pid=$!
  staging=""
  for _ in $(seq 1 50); do
    staging=$(echo "$BATCHES"/batch-*)
    [ -f "$staging/batch.json" ] && break
    sleep 0.1
  done
  # batch.json exists before any paper lands, so the dashboard can show it.
  [ "$(jq -r '.pages' "$staging/batch.json")" = "0" ]
  [ "$(jq -r '.ended' "$staging/batch.json")" = "null" ]
  [ "$(cat "$staging/.pid")" = "$pid" ]
  echo 2 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  for _ in $(seq 1 50); do [ -f "$staging/pages/page-002.jpg" ] && break; sleep 0.1; done
  touch "$staging/.stop"
  rc=0; wait "$pid" || rc=$?
  [ "$rc" -eq 0 ]
  grep -q "Stop requested." "$TMP/out"
  [ "$(jq -r '.pages' "$staging/batch.json")" = "2" ]
  [ "$(jq -r '.ended' "$staging/batch.json")" = "stop" ]
  [ ! -e "$staging/.pid" ]
  [ ! -e "$staging/.stop" ]
}

@test "--auto-started marks the batch, a resume keeps the mark, and a person's batch has none" {
  echo 2 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run "$SCAN_BATCH" -o "$BATCHES" --idle 1 --auto-started --user eric
  [ "$status" -eq 0 ]
  [[ "$output" == *"Started by auto-scan"* ]]
  staging=$(echo "$BATCHES"/batch-*)
  [ "$(jq -r '.auto' "$staging/batch.json")" = "true" ]
  [ "$(jq -r '.user' "$staging/batch.json")" = "eric" ]

  echo 2 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run "$SCAN_BATCH" --resume "$staging" --idle 1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.pages' "$staging/batch.json")" = "4" ]
  [ "$(jq -r '.auto' "$staging/batch.json")" = "true" ]

  echo 2 > "$SCANIMAGE_STUB_DIR/feed"
  echo yes > "$SCANIMAGE_STUB_DIR/sensor"
  run "$SCAN_BATCH" -o "$TMP/other" --idle 1
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("auto")' "$TMP"/other/batch-*/batch.json)" = "false" ]
}
