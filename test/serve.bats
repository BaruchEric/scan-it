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
  # Auto-scan: its settings stay in the scratch dir, and the watcher and
  # scan-batch poll fast enough for a test.
  export SCAN_AUTO_FILE="$TMP/auto.json"
  export SCAN_AUTO_POLL_SECS=0.3
  export SCAN_BATCH_POLL_SECS=1
  export SCANIMAGE_STUB_DIR="$TMP/stub"
  mkdir -p "$SCANIMAGE_STUB_DIR"
  export SCAN_BATCH_SCANIMAGE="$BATS_TEST_DIRNAME/stubs/scanimage"

  # Stands in for the Brother restart so tests never kill the real services.
  # It fails when $TMP/restart-fail exists.
  cat > "$TMP/restart" <<SH
#!/bin/sh
echo "Stopping the Brother services."
sleep 2
if [ -f "$TMP/restart-fail" ]; then echo "NETserver did not come back."; exit 1; fi
echo "All three Brother services are running."
SH
  chmod +x "$TMP/restart"
  export SCAN_BROTHER_RESTART="$TMP/restart"

  # Remote access as tailscale serve delivers it: this Host, plus the login header.
  export SCAN_SERVE_PUBLIC_URL="https://dash.example.ts.net:8445"
  export SCAN_SERVE_ALLOW_LOGINS="owner@example.com"

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

  # The edge URL as the beric-mac Cloudflare tunnel delivers it: its own
  # listener, this Host, and X-Gate-User from the edge Worker.
  EPORT=$(( PORT + 1 ))
  EURL="http://127.0.0.1:$EPORT"
  export SCAN_SERVE_EDGE_URL="https://scans.example.ca"
  export SCAN_SERVE_EDGE_ALLOW="owner@gate.example"
  export SCAN_SERVE_EDGE_PORT="$EPORT"
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
  if [[ "$(uname)" == Darwin ]]; then trash="$HOME/.Trash"; else trash="${XDG_DATA_HOME:-$HOME/.local/share}/Trash/files"; fi
  [ -d "$trash/batch-20261101-100000/pages" ]
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

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
RHOST="dash.example.ts.net:8445"
ROWN="https://dash.example.ts.net:8445"

@test "the public URL needs an allowed tailnet login" {
  [ "$(code -H "Host: $RHOST" "$URL/api/ping")" = "403" ]
  [ "$(code -H "Host: $RHOST" -H "Tailscale-User-Login: someone@example.com" "$URL/api/ping")" = "403" ]
  [ "$(code -H "Host: $RHOST" -H "Tailscale-User-Login: Owner@Example.com" "$URL/api/ping")" = "200" ]
  [ "$(code -H "Host: other.example.ts.net:8445" -H "Tailscale-User-Login: owner@example.com" "$URL/api/ping")" = "421" ]
  page=$(curl -fs -H "Host: $RHOST" -H "Tailscale-User-Login: owner@example.com" "$URL/")
  [[ "$page" == *'"remote":true'* ]]
  [[ "$page" == *'"url":"https://dash.example.ts.net:8445/"'* ]]
  [[ "$(curl -fs "$URL/")" == *'"remote":false'* ]]
}

@test "remote POSTs need the public origin, and can't open Finder on the Mac" {
  rpost() { # <path> <origin>
    curl -s -X POST -H "Host: $RHOST" -H "Tailscale-User-Login: owner@example.com" -H "Origin: $2" \
      -H "X-Scan-Token: $TOKEN" -H "Content-Type: application/json" -d '{}' -w '\n%{http_code}' "$URL$1"
  }
  run rpost /api/batches/batch-20261101-100000/stop "http://127.0.0.1:$PORT"
  [ "${lines[1]}" = "403" ]
  run rpost /api/batches/batch-20261101-100000/stop "$ROWN"
  [ "${lines[1]}" = "409" ]
  [[ "${lines[0]}" == *"not scanning"* ]]
  run rpost /api/batches/batch-20261101-100000/reveal "$ROWN"
  [ "${lines[1]}" = "409" ]
  # A Mac server refuses a remote viewer; a Linux server has no Finder at all.
  [[ "${lines[0]}" == *"only from that Mac"* || "${lines[0]}" == *"needs macOS"* ]]
  run rpost /api/reveal "$ROWN"
  [ "${lines[1]}" = "409" ]
}

@test "a public URL without an allowlist refuses to start" {
  SCAN_SERVE_ALLOW_LOGINS="" run bun "$BATS_TEST_DIRNAME/../share/server.ts" --root "$ROOT" \
    --staging "$STAGING" --port 1 --no-open
  [ "$status" -eq 64 ]
  [[ "$output" == *"--allow-login"* ]]
  run "$BATS_TEST_DIRNAME/../bin/scan-catalog" -r "$ROOT" serve --tunnel somehost
  [ "$status" -eq 64 ]
}

@test "a stale token is refused with code token, and /api/token hands out the current one" {
  run curl -s -X POST -H "X-Scan-Token: stale" -H "Content-Type: application/json" -d '{}' \
    -w '\n%{http_code}' "$URL/api/dashboard/refresh"
  [ "${lines[1]}" = "403" ]
  [ "$(jq -r .code <<<"${lines[0]}")" = "token" ]
  [ "$(curl -fs "$URL/api/token" | jq -r .token)" = "$TOKEN" ]
  # The token endpoint sits behind the same identity checks as the page.
  [ "$(code -H "Host: $RHOST" "$URL/api/token")" = "403" ]
  [ "$(code -H "Host: scans.example.ca" "$EURL/api/token")" = "403" ]
  [ "$(curl -fs -H "Host: scans.example.ca" -H "X-Gate-User: owner@gate.example" "$EURL/api/token" | jq -r .token)" = "$TOKEN" ]
  # A cross-origin refusal carries no code, so the page never retries it.
  run curl -s -X POST -H "Origin: https://evil.example" -H "X-Scan-Token: $TOKEN" -d '{}' "$URL/api/dashboard/refresh"
  [ "$(jq -r '.code // "none"' <<<"$output")" = "none" ]
}

EHOST="scans.example.ca"
EOWN="https://scans.example.ca"

@test "the edge URL answers on its own listener, for an allowed X-Gate-User only" {
  [ "$(code -H "Host: $EHOST" "$EURL/api/ping")" = "403" ]
  [ "$(code -H "Host: $EHOST" -H "X-Gate-User: someone@gate.example" "$EURL/api/ping")" = "403" ]
  [[ "$(curl -s -H "Host: $EHOST" -H "X-Gate-User: someone@gate.example" "$EURL/api/ping")" == *"signed in as someone@gate.example"* ]]
  [ "$(code -H "Host: $EHOST" -H "X-Gate-User: Owner@Gate.example" "$EURL/api/ping")" = "200" ]
  # The edge listener serves the edge URL and nothing else.
  [ "$(code -H "Host: 127.0.0.1:$EPORT" -H "X-Gate-User: owner@gate.example" "$EURL/api/ping")" = "421" ]
  [ "$(code -H "Host: 127.0.0.1:$PORT" "$EURL/api/ping")" = "421" ]
  page=$(curl -fs -H "Host: $EHOST" -H "X-Gate-User: owner@gate.example" "$EURL/")
  [[ "$page" == *'"remote":true'* ]]
  [[ "$page" == *'"url":"https://scans.example.ca/"'* ]]
}

@test "each URL trusts only its own identity header" {
  # Through Cloudflare anyone can send Tailscale-User-Login, even the tailnet owner's.
  [ "$(code -H "Host: $EHOST" -H "Tailscale-User-Login: owner@example.com" "$EURL/api/ping")" = "403" ]
  [ "$(code -H "Host: $RHOST" -H "Tailscale-User-Login: owner@example.com" "$EURL/api/ping")" = "421" ]
  # tailscale serve passes X-Gate-User through, so the main port never reads it.
  [ "$(code -H "Host: $RHOST" -H "X-Gate-User: owner@gate.example" "$URL/api/ping")" = "403" ]
  [ "$(code -H "Host: $EHOST" -H "X-Gate-User: owner@gate.example" "$URL/api/ping")" = "421" ]
}

@test "edge POSTs need the edge origin, and can't open Finder on the Mac" {
  epost() { # <path> <origin>
    curl -s -X POST -H "Host: $EHOST" -H "X-Gate-User: owner@gate.example" -H "Origin: $2" \
      -H "X-Scan-Token: $TOKEN" -H "Content-Type: application/json" -d '{}' -w '\n%{http_code}' "$EURL$1"
  }
  run epost /api/batches/batch-20261101-100000/stop "$ROWN"
  [ "${lines[1]}" = "403" ]
  run epost /api/batches/batch-20261101-100000/stop "$EOWN"
  [ "${lines[1]}" = "409" ]
  [[ "${lines[0]}" == *"not scanning"* ]]
  run epost /api/batches/batch-20261101-100000/reveal "$EOWN"
  [ "${lines[1]}" = "409" ]
  # A Mac server refuses a remote viewer; a Linux server has no Finder at all.
  [[ "${lines[0]}" == *"only from that Mac"* || "${lines[0]}" == *"needs macOS"* ]]
  run epost /api/reveal "$EOWN"
  [ "${lines[1]}" = "409" ]
}

@test "an edge URL without an allowlist, or on the main port, refuses to start" {
  SCAN_SERVE_EDGE_ALLOW="" run bun "$BATS_TEST_DIRNAME/../share/server.ts" --root "$ROOT" \
    --staging "$STAGING" --port 1 --no-open
  [ "$status" -eq 64 ]
  [[ "$output" == *"--edge-allow"* ]]
  run bun "$BATS_TEST_DIRNAME/../share/server.ts" --root "$ROOT" --staging "$STAGING" \
    --port 1 --edge-port 1 --no-open
  [ "$status" -eq 64 ]
  [[ "$output" == *"--edge-port must differ"* ]]
}

@test "scan-catalog serve passes the edge flags to the server" {
  local p=$(( EPORT + 1 )) e=$(( EPORT + 2 ))
  SCAN_SERVE_EDGE_URL="" SCAN_SERVE_EDGE_ALLOW="" SCAN_SERVE_EDGE_PORT="" \
    "$BATS_TEST_DIRNAME/../bin/scan-catalog" -r "$ROOT" serve --port "$p" --no-open \
    --edge-url https://edge.example.ca --edge-allow a@gate.example --edge-port "$e" > "$TMP/second.log" 2>&1 &
  SLEEPER=$!
  for _ in $(seq 1 50); do curl -fs -H "Host: edge.example.ca" -H "X-Gate-User: a@gate.example" \
    "http://127.0.0.1:$e/api/ping" >/dev/null 2>&1 && break; sleep 0.1; done
  [ "$(code -H "Host: edge.example.ca" -H "X-Gate-User: a@gate.example" "http://127.0.0.1:$e/api/ping")" = "200" ]
  grep -q "edge:        https://edge.example.ca/ for a@gate.example, via 127.0.0.1:$e" "$TMP/second.log"
}

wait_job() { # <job id>; prints the finished job's JSON
  local j
  for _ in $(seq 1 100); do
    j=$(curl -fs "$URL/api/jobs/$1")
    [ "$(jq -r .state <<<"$j")" != "running" ] && break
    sleep 0.1
  done
  echo "$j"
}

@test "a Brother restart shows on its card and blocks a second restart and Diagnose" {
  run post /api/brother/restart
  [ "${lines[1]}" = "200" ]
  job=$(jq -r .job <<<"${lines[0]}")
  st=$(curl -fs "$URL/api/status")
  [ "$(jq -r '.scanners[] | select(.slug=="brother") | .state' <<<"$st")" = "restarting" ]
  [ "$(jq -c '.scanners[] | select(.slug=="brother") | .actions' <<<"$st")" = "[]" ]
  [ "$(jq -r '.scanners[] | select(.slug=="ix500") | .state' <<<"$st")" != "restarting" ]
  [ "$(jq -r '.scanners[] | select(.slug=="ix500") | .actions | index("diag")' <<<"$st")" = "null" ]
  run post /api/brother/restart
  [ "${lines[1]}" = "409" ]
  [[ "${lines[0]}" == *"already restarting ($job)"* ]]
  run post /api/diag
  [ "${lines[1]}" = "409" ]
  [[ "${lines[0]}" == *"restarting"* ]]

  j=$(wait_job "$job")
  [ "$(jq -r .state <<<"$j")" = "done" ]
  [ "$(jq -r .summary <<<"$j")" = "All three Brother services are running." ]
  st=$(curl -fs "$URL/api/status")
  [ "$(jq -r '.scanners[] | select(.slug=="brother") | .state' <<<"$st")" = "idle" ]
  run post /api/brother/restart
  [ "${lines[1]}" = "200" ]
}

@test "a failed job carries its last output line as the summary" {
  touch "$TMP/restart-fail"
  run post /api/brother/restart
  [ "${lines[1]}" = "200" ]
  j=$(wait_job "$(jq -r .job <<<"${lines[0]}")")
  [ "$(jq -r .state <<<"$j")" = "failed" ]
  [ "$(jq -r .exit_code <<<"$j")" = "1" ]
  [ "$(jq -r .summary <<<"$j")" = "NETserver did not come back." ]
}

@test "scan-catalog serve opens an already running server instead of starting a second" {
  run "$BATS_TEST_DIRNAME/../bin/scan-catalog" -r "$ROOT" serve --port "$PORT" --no-open
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
}

@test "File runs batch-file, and its .filing lock blocks a second filer" {
  b=batch-20261101-100000
  cat > "$STAGING/$b/manifest.json" <<JSON
{ "batch": "$b", "documents": [],
  "review": [ { "pages": [ { "file": "pages/page-001.jpg", "rotate": 0 } ],
                "reason": "total unreadable", "guess": { "type": "receipt", "entity": "personal" } } ] }
JSON
  run post "/api/batches/$b/file"
  [ "${lines[1]}" = "200" ]
  job=$(jq -r .job <<<"${lines[0]}")
  for _ in $(seq 1 150); do
    st=$(curl -fs "$URL/api/jobs/$job" | jq -r .state)
    [ "$st" != "running" ] && break
    sleep 0.2
  done
  [ "$st" = "done" ]
  [ -f "$ROOT/_review/review-$b-01.pdf" ]
  run curl -fs "$URL/api/status"
  [ "$(jq -r ".batches[] | select(.id == \"$b\") | .state" <<<"$output")" = "filed" ]
  [ ! -e "$STAGING/$b/.filing" ]

  # Someone else is filing batch-20261102: the dashboard offers nothing but
  # Reveal, and a second batch-file refuses without touching the lock.
  r=batch-20261102-100000
  echo '{"batch":"'"$r"'","documents":[],"review":[{"pages":[{"file":"pages/page-001.jpg","rotate":0}],"reason":"x"}]}' \
    > "$STAGING/$r/manifest.json"
  mkdir "$STAGING/$r/.filing"
  run curl -fs "$URL/api/status"
  [ "$(jq -c ".batches[] | select(.id == \"$r\") | .actions" <<<"$output")" = '["reveal"]' ]
  run post "/api/batches/$r/file"
  [ "${lines[1]}" = "409" ]
  run env SCAN_DASHBOARD_TEMPLATE="$TMP/tpl.html" "$BATS_TEST_DIRNAME/../bin/batch-file" -o "$ROOT" --no-dashboard "$STAGING/$r"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already being filed"* ]]
  [ -d "$STAGING/$r/.filing" ]
  [ ! -e "$ROOT/_review/review-$r-01.pdf" ]
}

# A Brother whose feeder the test loads and empties: the file adf beside the
# stub holds Loaded or Empty. A scan writes two pages and empties the feeder.
# adf-status, when present, is what --status alone reports: paper the watcher
# sees and scan-batch's own sensor check doesn't, as when it lands between the
# two.
fake_brother() {
  echo "${1:-Empty}" > "$TMP/adf"
  cat > "$TMP/escl" <<'SH'
#!/bin/sh
dir=$(dirname "$0")
adf=$(cat "$dir/adf" 2>/dev/null || echo Empty)
out="" start=1
while [ $# -gt 0 ]; do
  case "$1" in
    --discover) echo "http://localhost:60000/eSCL"; exit 0 ;;
    --status) echo "State=Idle Adf=ScannerAdf$(cat "$dir/adf-status" 2>/dev/null || echo "$adf") Endpoint=http://localhost:60000/eSCL"; exit 0 ;;
    --page-loaded) [ "$adf" = Loaded ]; exit $? ;;
    -o) out="$2"; shift ;;
    --start) start="$2"; shift ;;
  esac
  shift
done
[ -n "$out" ] || exit 64
[ "$adf" = Loaded ] || exit 2
for n in "$start" $((start + 1)); do printf 'JPEG' > "$out/$(printf 'page-%03d.jpg' "$n")"; done
echo Empty > "$dir/adf"
echo "2 page(s) -> $out"
SH
  chmod +x "$TMP/escl"
}

auto_of() { curl -fs "$URL/api/status" | jq -r ".scanners[] | select(.slug == \"brother\") | .auto.$1"; }
auto_batches() { # staging dirs that auto-scan started, oldest first
  local f
  for f in "$STAGING"/batch-*/batch.json; do
    [ "$(jq -r '.auto // false' "$f" 2>/dev/null)" = "true" ] && basename "$(dirname "$f")"
  done
  return 0
}
wait_until() { # <tries of 0.2 s> <command...>
  local n="$1"; shift
  for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 0.2; done
  return 1
}
auto_count_is() { [ "$(auto_batches | wc -l | tr -d ' ')" = "$1" ]; }
auto_phase_is() { [ "$(auto_of phase)" = "$1" ]; }
batch_state_is() { [ "$(curl -fs "$URL/api/status" | jq -r ".batches[] | select(.id == \"$1\") | .state")" = "$2" ]; }

@test "auto-scan is off until someone turns it on, and its settings persist" {
  fake_brother Loaded
  [ "$(auto_of enabled)" = "false" ]
  [ "$(auto_of phase)" = "off" ]
  [ "$(curl -fs "$URL/api/status" | jq -r '.scanners[] | select(.slug == "ix500") | .auto')" = "null" ]
  # Off means off: paper in the feeder starts nothing.
  sleep 1.5
  auto_count_is 0
  [ ! -e "$TMP/auto.json" ]

  run post /api/auto '{"scanner":"brother","user":"eric","duplex":false,"gray":true,"idle":120}'
  [ "${lines[1]}" = "200" ]
  [ "$(jq -c .brother "$TMP/auto.json")" = '{"enabled":false,"user":"eric","duplex":false,"gray":true,"idle":120}' ]
  [ "$(auto_of idle)" = "120" ]
  # Fields left out keep their value.
  run post /api/auto '{"scanner":"brother","duplex":true}'
  [ "$(jq -c '.brother | [.duplex, .gray, .idle]' "$TMP/auto.json")" = '[true,true,120]' ]

  run post /api/auto '{"scanner":"ix500","enabled":true}'
  [ "${lines[1]}" = "409" ]
  [[ "${lines[0]}" == *"Brother only"* ]]
  run post /api/auto '{"scanner":"brother","user":"nobody"}'
  [ "${lines[1]}" = "400" ]
  run post /api/auto '{"scanner":"nope","enabled":true}'
  [ "${lines[1]}" = "400" ]
  run curl -s -o /dev/null -w '%{http_code}' -X POST -d '{"scanner":"brother","enabled":true}' "$URL/api/auto"
  [ "$output" = "403" ]
  [ "$(jq -r .brother.enabled "$TMP/auto.json")" = "false" ]
}

@test "auto-scan starts one batch per feed, and holds while leftover paper sits in the feeder" {
  fake_brother Empty
  run post /api/auto '{"scanner":"brother","enabled":true,"user":"eric","idle":10}'
  [ "${lines[1]}" = "200" ]
  wait_until 25 auto_phase_is watching
  sleep 1
  auto_count_is 0

  # Paper lands: a batch starts by itself, recorded as the auto-scan user.
  echo Loaded > "$TMP/adf"
  wait_until 50 auto_count_is 1
  first=$(auto_batches | head -1)
  wait_until 50 test -f "$STAGING/$first/pages/page-002.jpg"
  [ "$(jq -r .user "$STAGING/$first/batch.json")" = "eric" ]
  [ "$(jq -r .source "$STAGING/$first/batch.json")" = "ADF Duplex" ]
  st=$(curl -fs "$URL/api/status")
  [ "$(jq -r ".batches[] | select(.id == \"$first\") | .state" <<<"$st")" = "scanning" ]
  [ "$(jq -r ".batches[] | select(.id == \"$first\") | .auto" <<<"$st")" = "true" ]
  [ "$(jq -r '.scanners[] | select(.slug == "brother") | .auto.phase' <<<"$st")" = "scanning" ]
  [ "$(jq -r '[.jobs[] | select(.label | startswith("Auto-scan on"))] | length' <<<"$st")" = "1" ]
  # The Scan button can't start a second batch on a scanner that is scanning.
  run post /api/scan '{"scanner":"brother","user":"eric"}'
  [ "${lines[1]}" = "409" ]

  # The batch ends with the feeder empty, so the next feed starts a second one.
  touch "$STAGING/$first/.stop"
  wait_until 50 batch_state_is "$first" staged
  wait_until 25 auto_phase_is watching
  sleep 1
  auto_count_is 1
  echo Loaded > "$TMP/adf"
  wait_until 50 auto_count_is 2
  second=$(auto_batches | tail -1)
  [ "$second" != "$first" ]
  wait_until 50 test -f "$STAGING/$second/pages/page-002.jpg"

  # Stopped with paper still in the feeder: that paper is not a new feed.
  touch "$STAGING/$second/.stop"
  echo Loaded > "$TMP/adf"
  wait_until 50 batch_state_is "$second" staged
  wait_until 25 auto_phase_is holding
  sleep 2
  auto_count_is 2
  # Taken out and loaded again, it is.
  echo Empty > "$TMP/adf"
  wait_until 25 auto_phase_is watching
  echo Loaded > "$TMP/adf"
  wait_until 50 auto_count_is 3

  # Switched off mid-batch: the batch finishes, and nothing starts after it.
  third=$(auto_batches | tail -1)
  run post /api/auto '{"scanner":"brother","enabled":false}'
  [ "${lines[1]}" = "200" ]
  wait_until 50 test -f "$STAGING/$third/pages/page-002.jpg"
  touch "$STAGING/$third/.stop"
  wait_until 50 batch_state_is "$third" staged
  echo Loaded > "$TMP/adf"
  sleep 2
  auto_count_is 3
  [ "$(auto_of phase)" = "off" ]
}

@test "auto-scan takes paper that lands just as a batch ends by its idle timeout" {
  fake_brother Loaded
  run post /api/auto '{"scanner":"brother","enabled":true,"user":"eric","idle":10}'
  [ "${lines[1]}" = "200" ]
  wait_until 50 auto_count_is 1
  first=$(auto_batches | head -1)
  wait_until 50 test -f "$STAGING/$first/pages/page-002.jpg"
  # From here the watcher would see paper, and scan-batch never does: it runs
  # out its idle time on a feeder it found empty at every look.
  echo Loaded > "$TMP/adf-status"
  wait_until 100 batch_state_is "$first" staged
  [ "$(jq -r .ended "$STAGING/$first/batch.json")" = "idle" ]
  [ "$(jq -r .pages "$STAGING/$first/batch.json")" = "2" ]
  # The watcher never saw the feeder empty in between. The paper still counts.
  wait_until 50 auto_count_is 2
  second=$(auto_batches | tail -1)
  [ "$second" != "$first" ]
  # scan-batch finds no paper for the second batch, so stopping it leaves nothing staged.
  rm "$TMP/adf-status"
  touch "$STAGING/$second/.stop"
  wait_until 50 test ! -d "$STAGING/$second"
}

@test "auto-scan that is already on scans paper waiting when the server starts" {
  fake_brother Loaded
  kill "$SERVER"; wait "$SERVER" 2>/dev/null || true
  echo '{"brother":{"enabled":true,"user":"eric","duplex":false,"gray":true,"idle":10}}' > "$TMP/auto.json"
  bun "$BATS_TEST_DIRNAME/../share/server.ts" --root "$ROOT" --staging "$STAGING" \
    --port "$PORT" --no-open > "$TMP/server2.log" 2>&1 &
  SERVER=$!
  wait_until 50 auto_count_is 1
  b=$(auto_batches | head -1)
  wait_until 50 test -f "$STAGING/$b/pages/page-001.jpg"
  [ "$(jq -r .source "$STAGING/$b/batch.json")" = "ADF Front" ]
  [ "$(jq -r .mode "$STAGING/$b/batch.json")" = "Gray" ]
  grep -q "auto-scan: paper in the Brother ADS-4300N, starting a batch as eric" "$TMP/server2.log"
  touch "$STAGING/$b/.stop"
  wait_until 50 batch_state_is "$b" staged
}
