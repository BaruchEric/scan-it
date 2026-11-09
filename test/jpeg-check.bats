#!/usr/bin/env bats
# bin/jpeg-check against synthetic JPEGs: one restart marker per MCU row, as
# the Brother writes them, then cut short or cut open by test/helpers/jpeg-cut.ts.

setup() {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  command -v jpegtran >/dev/null 2>&1 || skip "jpegtran not installed"
  command -v magick >/dev/null 2>&1 || skip "imagemagick not installed"
  TMP=$(mktemp -d)
  CHECK="$BATS_TEST_DIRNAME/../bin/jpeg-check"
  CUT="$BATS_TEST_DIRNAME/helpers/jpeg-cut.ts"
  # 320x480 with 2x2 chroma subsampling: 16-row MCUs, 30 rows, 29 markers.
  magick -size 320x480 gradient:white-navy -quality 90 -sampling-factor 2x2 "$TMP/plain.jpg"
  jpegtran -restart 1 -outfile "$TMP/clean.jpg" "$TMP/plain.jpg"
}

teardown() { rm -rf "$TMP"; }

height() { magick identify -format '%h' "$1" 2>/dev/null; }

@test "a complete page is ok" {
  run "$CHECK" "$TMP/clean.jpg"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok $TMP/clean.jpg" ]]
}

@test "a page that stops early is reported truncated, counting only closed rows" {
  bun "$CUT" truncate "$TMP/clean.jpg" "$TMP/short.jpg" 12
  run "$CHECK" "$TMP/short.jpg"
  [ "$status" -eq 0 ]
  [[ "$output" == "truncated $TMP/short.jpg (192 of 480 rows)" ]]
}

@test "--repair crops a truncated page losslessly to a clean file" {
  bun "$CUT" truncate "$TMP/clean.jpg" "$TMP/short.jpg" 12
  run "$CHECK" --repair "$TMP/short.jpg"
  [ "$status" -eq 0 ]
  [[ "$output" == "cropped $TMP/short.jpg (192 of 480 rows)" ]]
  [ "$(height "$TMP/short.jpg")" = "192" ]
  ! magick identify "$TMP/short.jpg" 2>&1 | grep -qi corrupt
  run "$CHECK" "$TMP/short.jpg"
  [[ "$output" == "ok $TMP/short.jpg" ]]
}

@test "rows missing mid-page are damaged, exit 4, and --repair leaves the file alone" {
  bun "$CUT" drop "$TMP/clean.jpg" "$TMP/hole.jpg" 10
  before=$(shasum "$TMP/hole.jpg")
  run "$CHECK" --repair "$TMP/hole.jpg"
  [ "$status" -eq 4 ]
  [[ "$output" == "damaged $TMP/hole.jpg"* ]]
  [ "$(shasum "$TMP/hole.jpg")" = "$before" ]
}

@test "a JPEG without restart markers is unknown and untouched" {
  before=$(shasum "$TMP/plain.jpg")
  run "$CHECK" --repair "$TMP/plain.jpg"
  [ "$status" -eq 0 ]
  [[ "$output" == "unknown $TMP/plain.jpg (no restart markers)" ]]
  [ "$(shasum "$TMP/plain.jpg")" = "$before" ]
}

@test "an unreadable file exits 1, other files are still checked" {
  run "$CHECK" "$TMP/missing.jpg" "$TMP/clean.jpg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read $TMP/missing.jpg"* ]]
  [[ "$output" == *"ok $TMP/clean.jpg"* ]]
}

@test "scan-batch lists escl-scan's damaged pages in batch.json and warns" {
  # A Brother stand-in: one 2-page chunk, page 2 flagged the way escl-scan does.
  cat > "$TMP/escl" <<SH
#!/bin/sh
case "\$1" in
  --discover) echo "http://localhost:60000/eSCL"; exit 0 ;;
  --page-loaded) [ -f "$TMP/sensor" ] && exit 0 || exit 1 ;;
esac
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift ;; --start) start="\$2"; shift ;; esac
  shift
done
cp "$TMP/clean.jpg" "\$out/page-001.jpg"
cp "$TMP/clean.jpg" "\$out/page-002.jpg"
echo "page-002.jpg" >> "\$out/.damaged"
rm -f "$TMP/sensor"
SH
  chmod +x "$TMP/escl"
  touch "$TMP/sensor"
  export SCAN_BATCH_ESCL="$TMP/escl" SCAN_SCANNER=brother SCAN_BATCH_POLL_SECS=1
  run "$BATS_TEST_DIRNAME/../bin/scan-batch" -o "$TMP/batches" --idle 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"damaged page(s), rescan those sheets: pages/page-002.jpg"* ]]
  staging=$(echo "$TMP"/batches/batch-*)
  [ "$(jq -c '.damaged' "$staging/batch.json")" = '["pages/page-002.jpg"]' ]
}

@test "escl-scan crops short pages and records damaged ones as they arrive" {
  bun "$CUT" truncate "$TMP/clean.jpg" "$TMP/short.jpg" 12
  bun "$CUT" drop "$TMP/clean.jpg" "$TMP/hole.jpg" 10
  bun "$BATS_TEST_DIRNAME/helpers/fake-escl.ts" "$TMP/port" \
    "$TMP/clean.jpg" "$TMP/short.jpg" "$TMP/hole.jpg" 3>&- &
  server=$!
  for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
  run "$BATS_TEST_DIRNAME/../bin/escl-scan" --endpoint "http://127.0.0.1:$(cat "$TMP/port")/eSCL" -o "$TMP/pages"
  kill "$server" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"Page 2: paper ended early; cropped"* ]]
  [[ "$output" == *"page 3 lost rows mid-page"* ]]
  [ "$(height "$TMP/pages/page-001.jpg")" = "480" ]
  [ "$(height "$TMP/pages/page-002.jpg")" = "192" ]
  [ "$(cat "$TMP/pages/.damaged")" = "page-003.jpg" ]
  cmp -s "$TMP/hole.jpg" "$TMP/pages/page-003.jpg"
}

@test "escl-scan keeps the page as received when the check is off" {
  bun "$CUT" truncate "$TMP/clean.jpg" "$TMP/short.jpg" 12
  bun "$BATS_TEST_DIRNAME/helpers/fake-escl.ts" "$TMP/port" "$TMP/short.jpg" 3>&- &
  server=$!
  for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
  ESCL_SCAN_CHECK=0 run "$BATS_TEST_DIRNAME/../bin/escl-scan" --endpoint "http://127.0.0.1:$(cat "$TMP/port")/eSCL" -o "$TMP/pages"
  kill "$server" 2>/dev/null || true
  [ "$status" -eq 0 ]
  cmp -s "$TMP/short.jpg" "$TMP/pages/page-001.jpg"
}
