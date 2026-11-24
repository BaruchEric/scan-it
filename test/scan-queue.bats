#!/usr/bin/env bats
# bin/scan-queue: previews of unfiled batches in <root>/_queue, and the
# catalog's view of them.

setup() {
  command -v magick >/dev/null 2>&1 || skip "magick not installed"
  command -v img2pdf >/dev/null 2>&1 || skip "img2pdf not installed"
  TMP=$(mktemp -d)
  ROOT="$TMP/scans"
  STAGING="$TMP/batches"
  Q="$BATS_TEST_DIRNAME/../bin/scan-queue"
  CAT="$BATS_TEST_DIRNAME/../bin/scan-catalog"
  mkdir -p "$ROOT" "$STAGING"
  export SCAN_QUEUE_KICK=0
  cat > "$ROOT/entities.json" <<'JSON'
{ "entities": [ { "slug": "personal", "name": "Personal", "kind": "personal" } ] }
JSON
}

teardown() {
  [[ -z "${FAKE_PID:-}" ]] || kill "$FAKE_PID" 2>/dev/null || true
  rm -rf "$TMP"
}

# stage <id> <pages> [ended]: a staging dir as scan-batch leaves it.
stage() {
  local dir="$STAGING/$1" i
  mkdir -p "$dir/pages"
  for (( i = 1; i <= $2; i++ )); do
    magick -size 60x80 xc:white "$dir/pages/$(printf 'page-%03d.jpg' "$i")"
  done
  jq -n --arg id "$1" --argjson pages "$2" --arg ended "${3-idle}" '
    {batch: $id, started: "2026-11-23T17:06:12-0800", updated: "2026-11-23T17:07:17-0800",
     source: "ADF Duplex", mode: "Color", resolution: 300, pages: $pages, damaged: [],
     scanner: "brother", user: "eric", default_entity: null, auto: true,
     ended: (if $ended == "" then null else $ended end)}' > "$dir/batch.json"
}

sync() { "$Q" -r "$ROOT" -s "$STAGING" sync; }

@test "a finished batch gets a preview PDF and a queue entry" {
  stage batch-20261123-170612 2
  run sync
  [ "$status" -eq 0 ]
  [ -f "$ROOT/_queue/batch-20261123-170612.pdf" ]
  [ "$(qpdf --show-npages "$ROOT/_queue/batch-20261123-170612.pdf")" = "2" ]
  run jq -r '.batches[0] | [.id, .state, .pages, .user, .auto, .file] | @tsv' "$ROOT/_queue/queue.json"
  [ "$output" = "$(printf 'batch-20261123-170612\tstaged\t2\teric\ttrue\t_queue/batch-20261123-170612.pdf')" ]
}

@test "the preview is 150 dpi, half the scan's pixels" {
  stage batch-20261123-170612 1
  sync
  command -v pdfimages >/dev/null 2>&1 || skip "pdfimages not installed"
  run pdfimages -list "$ROOT/_queue/batch-20261123-170612.pdf"
  [[ "$output" == *" 30 "*" 40 "* ]]
}

@test "a batch with a manifest is ready" {
  stage batch-20261123-170612 2
  echo '{}' > "$STAGING/batch-20261123-170612/manifest.json"
  sync
  [ "$(jq -r '.batches[0].state' "$ROOT/_queue/queue.json")" = "ready" ]
}

@test "filed and discarded batches leave the queue" {
  stage batch-20261123-170612 2
  stage batch-20261123-180000 2
  sync
  [ "$(jq '.batches | length' "$ROOT/_queue/queue.json")" = "2" ]
  date > "$STAGING/batch-20261123-170612/.filed"
  rm -rf "$STAGING/batch-20261123-180000"
  run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"dropped batch-20261123-170612"* ]]
  [[ "$output" == *"dropped batch-20261123-180000"* ]]
  [ "$(jq '.batches | length' "$ROOT/_queue/queue.json")" = "0" ]
  [ -z "$(ls "$ROOT/_queue"/*.pdf 2>/dev/null)" ]
}

@test "a batch still scanning stays out until it ends" {
  stage batch-20261123-170612 2 ""
  printf '#!/bin/sh\nsleep 30\n' > "$TMP/scan-batch"
  chmod +x "$TMP/scan-batch"
  "$TMP/scan-batch" &
  FAKE_PID=$!
  echo "$FAKE_PID" > "$STAGING/batch-20261123-170612/.pid"
  sync
  [ "$(jq '.batches | length' "$ROOT/_queue/queue.json")" = "0" ]
  # batch.json says it ended: queued even though the process is still exiting.
  jq '.ended = "idle"' "$STAGING/batch-20261123-170612/batch.json" > "$TMP/b" \
    && mv "$TMP/b" "$STAGING/batch-20261123-170612/batch.json"
  sync
  [ "$(jq '.batches | length' "$ROOT/_queue/queue.json")" = "1" ]
}

@test "a dead pid without ended does not hide the batch" {
  stage batch-20261123-170612 2 ""
  echo 999999 > "$STAGING/batch-20261123-170612/.pid"
  sync
  [ "$(jq '.batches | length' "$ROOT/_queue/queue.json")" = "1" ]
}

@test "a second sync with nothing new rewrites nothing" {
  stage batch-20261123-170612 2
  sync
  touch -t 202601010000 "$ROOT/_queue/batch-20261123-170612.pdf" "$ROOT/_queue/queue.json"
  run sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"queued"* ]]
  [ -z "$(find "$ROOT/_queue" -newer "$ROOT/entities.json" -name '*.pdf' -o -newer "$ROOT/entities.json" -name '*.json')" ]
}

@test "a resumed batch gets a new preview" {
  stage batch-20261123-170612 2
  sync
  magick -size 60x80 xc:white "$STAGING/batch-20261123-170612/pages/page-003.jpg"
  jq '.updated = "2026-11-23T17:20:00-0800" | .pages = 3' "$STAGING/batch-20261123-170612/batch.json" > "$TMP/b" \
    && mv "$TMP/b" "$STAGING/batch-20261123-170612/batch.json"
  run sync
  [[ "$output" == *"queued batch-20261123-170612 (3 pages"* ]]
  [ "$(qpdf --show-npages "$ROOT/_queue/batch-20261123-170612.pdf")" = "3" ]
}

@test "the catalog lists the queue on the full dashboard only, never as documents" {
  stage batch-20261123-170612 2
  sync
  run "$CAT" -r "$ROOT" build
  [ "$status" -eq 0 ]
  [ "$(jq '.queue | length' <<<"$output")" = "1" ]
  [ "$(jq '.documents | length' <<<"$output")" = "0" ]
  run "$CAT" -r "$ROOT" build --entity personal
  [ "$(jq '.queue | length' <<<"$output")" = "0" ]
  grep -q 'batch-20261123-170612' "$ROOT/dashboard.html"
}

@test "list prints each batch with its preview path" {
  stage batch-20261123-170612 2
  sync
  run "$Q" -r "$ROOT" list
  [ "$status" -eq 0 ]
  [[ "$output" == "batch-20261123-170612"*"staged"*"2p"*"eric"*"$ROOT/_queue/batch-20261123-170612.pdf" ]]
  run "$Q" -r "$ROOT" list --json
  [ "$(jq '.batches | length' <<<"$output")" = "1" ]
}

@test "list on a root with no queue prints nothing" {
  run "$Q" -r "$ROOT" list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "kick does nothing where the mirror unit is not installed" {
  HOME="$TMP/home" SCAN_QUEUE_KICK=1 run "$Q" kick
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
