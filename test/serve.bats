#!/usr/bin/env bats
# share/server.ts (scan-catalog serve) against a scratch filing root and
# staging dir. The scanners are stubs: test/stubs/scanimage for the iX500 and
# a one-line escl-scan stand-in for the Brother, so no hardware is touched.

setup() {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  TMP=$(mktemp -d)
  ROOT="$TMP/root"
  STAGING="$TMP/staging"
  export HOME="$TMP/home"
  mkdir -p "$ROOT/personal/medical" "$STAGING" "$HOME"
  cat > "$ROOT/profiles.json" <<'JSON'
{ "users": [ { "slug": "eric", "name": "Eric", "accounts": [] } ],
  "scanners": [ { "slug": "brother", "model": "Brother ADS-4300N", "where": "desk" },
                { "slug": "ix500", "model": "Fujitsu ScanSnap iX500" } ] }
JSON
  echo '{"entities":[{"slug":"personal","name":"Personal"}]}' > "$ROOT/entities.json"
  printf '%%PDF-1.4 test\n' > "$ROOT/personal/medical/labs.pdf"

  cat > "$TMP/escl" <<'SH'
#!/bin/sh
echo "State=Idle Adf=ScannerAdfLoaded Endpoint=http://localhost:60000/eSCL"
SH
  chmod +x "$TMP/escl"
  export SCAN_BATCH_ESCL="$TMP/escl"
  export SCANIMAGE_STUB_DIR="$TMP/stub"
  mkdir -p "$SCANIMAGE_STUB_DIR"
  export SCAN_BATCH_SCANIMAGE="$BATS_TEST_DIRNAME/stubs/scanimage"

  cat > "$TMP/tpl.html" <<'HTML'
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; img-src data:">
<script id="catalog" type="application/json">
/*__CATALOG__*/
</script>
<script id="live" type="application/json">
/*__LIVE__*/
</script>
HTML
  export SCAN_DASHBOARD_TEMPLATE="$TMP/tpl.html"

  # staged: pages only. ready: a manifest. filed: .filed after batch-file kept it.
  for b in batch-20261101-100000 batch-20261102-100000 batch-20261103-100000; do
    mkdir -p "$STAGING/$b/pages"
    magick -size 60x80 xc:white "$STAGING/$b/pages/page-001.jpg"
    echo '{"batch":"'"$b"'","source":"ADF Duplex","mode":"Color","resolution":300,"scanner":"brother","user":"eric","started":"2026-11-01T10:00:00-0800"}' \
      > "$STAGING/$b/batch.json"
  done
  echo '{"documents":[{}],"review":[]}' > "$STAGING/batch-20261102-100000/manifest.json"
  echo '{"documents":[],"review":[{}]}' > "$STAGING/batch-20261103-100000/manifest.json"
  date > "$STAGING/batch-20261103-100000/.filed"

  PORT=$(( 20000 + RANDOM % 20000 ))
  URL="http://127.0.0.1:$PORT"
  bun "$BATS_TEST_DIRNAME/../share/server.ts" --root "$ROOT" --staging "$STAGING" \
    --port "$PORT" --no-open > "$TMP/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 50); do curl -fs "$URL/api/ping" >/dev/null 2>&1 && break; sleep 0.1; done
  TOKEN=$(curl -fs "$URL/" | grep -o '"token":"[0-9a-f]*"' | cut -d'"' -f4)
}

teardown() {
  [ -z "${SERVER:-}" ] || kill "$SERVER" 2>/dev/null || true
  [ -z "${SLEEPER:-}" ] || kill "$SLEEPER" 2>/dev/null || true
  rm -rf "$TMP"
}

post() { # <path> [json]
  local body="${2:-}"
  [ -n "$body" ] || body='{}'
  curl -s -X POST -H "X-Scan-Token: $TOKEN" -H "Content-Type: application/json" \
    -d "$body" -w '\n%{http_code}' "$URL$1"
}

@test "page carries the token, the catalog with /files/ links, and a CSP that allows same-origin fetch" {
  [ "${#TOKEN}" -eq 48 ]
  html=$(curl -fs "$URL/")
  [[ "$html" == *"connect-src 'self'"* ]]
  [[ "$html" == *"img-src 'self' data:"* ]]
  [[ "$html" != *"__CATALOG__"* && "$html" != *"__LIVE__"* ]]
  sed -n '/<script id="catalog"/,/<\/script>/p' <<<"$html" | sed '1d;$d' | jq -e '.link_prefix == "/files/"' >/dev/null
  sed -n '/<script id="live"/,/<\/script>/p' <<<"$html" | sed '1d;$d' | jq -e '.default_user and .mock == false' >/dev/null
}

@test "status reports batch states, actions and stubbed scanner state" {
  run curl -fs "$URL/api/status"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.batches[] | select(.id == "batch-20261101-100000") | .state' <<<"$output")" = "staged" ]
  [ "$(jq -r '.batches[] | select(.id == "batch-20261102-100000") | .state' <<<"$output")" = "ready" ]
  [ "$(jq -r '.batches[] | select(.id == "batch-20261103-100000") | .state' <<<"$output")" = "filed" ]
  [ "$(jq -c '.batches[] | select(.id == "batch-20261102-100000") | .actions' <<<"$output")" = '["file","analyze","reveal","discard"]' ]
  [ "$(jq -r '.batches[] | select(.id == "batch-20261101-100000") | .odd_pages' <<<"$output")" = "true" ]
  [ "$(jq -r '.batches[0].started' <<<"$output")" = "2026-11-01T10:00:00-08:00" ]
  [ "$(jq -r '.scanners[] | select(.slug == "brother") | .state' <<<"$output")" = "idle" ]
  [ "$(jq -r '.scanners[] | select(.slug == "brother") | .paper' <<<"$output")" = "true" ]
  [ "$(jq -r '.scanners[] | select(.slug == "brother") | .connection' <<<"$output")" = "usb" ]
}

@test "POST without the token, from another origin, or to another Host is refused" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "$URL/api/diag"
  [ "$output" = "403" ]
  run curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Scan-Token: $TOKEN" -H 'Origin: http://evil.example' -d '{}' "$URL/api/diag"
  [ "$output" = "403" ]
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.example:$PORT" "$URL/api/status"
  [ "$output" = "421" ]
}

@test "actions are checked against the batch state" {
  run post /api/batches/batch-20261101-100000/file
  [ "${lines[1]}" = "409" ]
  [[ "${lines[0]}" == *"no manifest yet"* ]]
  run post /api/batches/batch-20261101-100000/stop
  [ "${lines[1]}" = "409" ]
  run post /api/batches/batch-nope/file
  [ "${lines[1]}" = "404" ]
}

@test "discard moves the staging dir to the Trash" {
  run post /api/batches/batch-20261101-100000/discard
  [ "${lines[1]}" = "200" ]
  [ ! -d "$STAGING/batch-20261101-100000" ]
  [ -d "$HOME/.Trash/batch-20261101-100000/pages" ]
}

@test "a live scan-batch shows as scanning, and Stop drops the .stop file" {
  mkdir -p "$TMP/fake"
  printf '#!/bin/sh\nsleep 30\n' > "$TMP/fake/scan-batch"
  chmod +x "$TMP/fake/scan-batch"
  "$TMP/fake/scan-batch" &
  SLEEPER=$!
  echo "$SLEEPER" > "$STAGING/batch-20261101-100000/.pid"
  run curl -fs "$URL/api/status"
  [ "$(jq -r '.batches[] | select(.id == "batch-20261101-100000") | .state' <<<"$output")" = "scanning" ]
  [ "$(jq -r '.scanners[] | select(.slug == "brother") | .state' <<<"$output")" = "scanning" ]
  run post /api/batches/batch-20261101-100000/stop
  [ "${lines[1]}" = "200" ]
  [ -f "$STAGING/batch-20261101-100000/.stop" ]
  run curl -fs "$URL/api/status"
  [ "$(jq -r '.batches[] | select(.id == "batch-20261101-100000") | .state' <<<"$output")" = "stopping" ]
  # A .pid left by a dead process means staged, not scanning.
  kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null || true
  run curl -fs "$URL/api/status"
  [ "$(jq -r '.batches[] | select(.id == "batch-20261101-100000") | .state' <<<"$output")" = "staged" ]
}

@test "thumbnails come from the staged pages; PDFs serve from the root only" {
  run curl -s -o "$TMP/t.jpg" -w '%{http_code} %{content_type}' "$URL/api/batches/batch-20261101-100000/thumb/1"
  [ "$output" = "200 image/jpeg" ]
  [ -f "$STAGING/.thumbs/batch-20261101-100000/page-001.jpg" ]
  run curl -s -o /dev/null -w '%{http_code}' "$URL/api/batches/batch-20261101-100000/thumb/9"
  [ "$output" = "404" ]
  run curl -s -o /dev/null -w '%{http_code} %{content_type}' "$URL/files/personal/medical/labs.pdf"
  [ "$output" = "200 application/pdf" ]
  run curl -s -o /dev/null -w '%{http_code}' "$URL/files/..%2fprofiles.json"
  [ "$output" = "404" ]
  run curl -s -o /dev/null -w '%{http_code}' --path-as-is "$URL/files/../root/profiles.json"
  [ "$output" = "404" ]
}

@test "a diag job runs scan-diag and keeps its output" {
  run post /api/diag
  [ "${lines[1]}" = "200" ]
  job=$(jq -r .job <<<"${lines[0]}")
  for _ in $(seq 1 100); do
    st=$(curl -fs "$URL/api/jobs/$job" | jq -r .state)
    [ "$st" != "running" ] && break
    sleep 0.2
  done
  [ "$st" != "running" ]
  curl -fs "$URL/api/jobs/$job" | jq -r .output | grep -q "scan-diag"
  ls "$STAGING/.logs/"*"-$job-diag.log"
}

@test "scan-catalog serve opens an already running server instead of starting a second" {
  run "$BATS_TEST_DIRNAME/../bin/scan-catalog" -r "$ROOT" serve --port "$PORT" --no-open
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
}
