#!/usr/bin/env bats
# bin/scan-catalog: catalog from sidecars, follow-up queue, marks, dashboards.

setup() {
  TMP=$(mktemp -d)
  ROOT="$TMP/scans"
  CAT="$BATS_TEST_DIRNAME/../bin/scan-catalog"
  mkdir -p "$ROOT/rio-laundromat/receipts/2026" "$ROOT/personal/medical" \
           "$ROOT/rio-laundromat/paychecks/2026" "$ROOT/_review" "$ROOT/_index"
  cat > "$ROOT/entities.json" <<'JSON'
{ "entities": [ { "slug": "personal", "name": "Personal", "kind": "personal" },
                { "slug": "rio-laundromat", "name": "RIO LAUNDROMAT LLC", "kind": "business", "quickbooks": true } ] }
JSON
  cat > "$ROOT/profiles.json" <<'JSON'
{ "users": [ { "slug": "eric", "name": "Eric" } ],
  "scanners": [ { "slug": "brother", "model": "Brother ADS-4300N" } ] }
JSON
  R="$ROOT/rio-laundromat/receipts/2026/receipt-2026-06-08-home-depot \$45.23"
  printf pdf > "$R.pdf"
  cat > "$R.json" <<'JSON'
{ "type": "receipt", "name": "receipt-2026-06-08-home-depot $45.23", "entity": "rio-laundromat",
  "date": "2026-06-08", "year": "2026", "fields": { "vendor": "Home Depot", "total": 45.23 },
  "text": ["SECRET OCR TEXT"], "confidence": "high",
  "source": { "batch": "b1", "pages": ["pages/page-001.jpg"], "scanner": "brother", "user": "eric", "host": "mac" },
  "filed": "2026-06-11T12:00:00-0700",
  "followups": { "quickbooks": { "status": "pending", "note": null, "updated": "x", "ref": null } } }
JSON
  M="$ROOT/personal/medical/lab-results-timma-2026-06-01"
  printf pdf > "$M.pdf"
  cat > "$M.json" <<'JSON'
{ "type": "medical", "name": "lab-results-timma-2026-06-01", "entity": "personal",
  "date": "2026-06-01", "fields": {}, "source": { "batch": "b1", "pages": ["a", "b"] },
  "followups": { "vault": { "status": "done", "note": null, "updated": "x", "ref": null } } }
JSON
  cat > "$ROOT/rio-laundromat/paychecks/2026/checks20260605.json" <<'JSON'
{ "type": "paycheck", "entity": "rio-laundromat", "name": "checks20260605", "paydate": "2026-06-05",
  "checks": [ { "check_number": 1001, "payee": "J", "amount": 10, "signed": true, "batch": "b1" } ],
  "sources": [ { "batch": "b1" } ],
  "followups": { "check_report": { "status": "pending", "note": null, "updated": "x", "ref": null } } }
JSON
  cat > "$ROOT/_review/review-b1-01.json" <<'JSON'
{ "reason": "total unreadable", "guess": { "type": "receipt", "entity": "personal" }, "source": { "batch": "b1", "pages": ["p"] } }
JSON
  echo '{"file":"x"}' > "$ROOT/_index/eric@mac.jsonl"
}

teardown() { rm -rf "$TMP"; }

@test "build merges sidecars, drops OCR text, parses the amount from the name" {
  run "$CAT" -r "$ROOT" build
  [ "$status" -eq 0 ]
  [ "$(jq '.documents | length' <<<"$output")" = "2" ]
  [ "$(jq '.paychecks | length' <<<"$output")" = "1" ]
  [ "$(jq '.review | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.documents[] | select(.type == "receipt") | .amount' <<<"$output")" = "45.23" ]
  [ "$(jq -r '.documents[] | select(.type == "medical") | .pages' <<<"$output")" = "2" ]
  [ "$(jq -r '.scope' <<<"$output")" = "all" ]
  [[ "$output" != *"SECRET OCR TEXT"* ]]
  [ "$(jq -r '.users[0].name' <<<"$output")" = "Eric" ]
}

@test "build --entity keeps only that entity, with paths relative to its folder" {
  run "$CAT" -r "$ROOT" build --entity rio-laundromat
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.documents[].entity] | unique' <<<"$output")" = '["rio-laundromat"]' ]
  [ "$(jq -r '.link_prefix' <<<"$output")" = "" ]
  [ "$(jq -r '.documents[0].file' <<<"$output")" = "receipts/2026/receipt-2026-06-08-home-depot \$45.23.pdf" ]
  [ "$(jq -r '.paychecks[0].file' <<<"$output")" = "paychecks/2026/checks20260605.pdf" ]
  [ "$(jq '.review | length' <<<"$output")" = "0" ]
  [ "$(jq -c '[.entities[].slug]' <<<"$output")" = '["rio-laundromat"]' ]
}

@test "pending lists open follow-ups across documents and paychecks" {
  run "$CAT" -r "$ROOT" pending
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "2" ]
  [[ "$output" == *"quickbooks"*"pending"*"rio-laundromat"* ]]
  [[ "$output" == *"check_report"* ]]
  run "$CAT" -r "$ROOT" pending quickbooks --json
  [ "$(jq -r '.fields.vendor' <<<"$output")" = "Home Depot" ]
}

@test "mark records the outcome in the sidecar and clears it from pending" {
  run "$CAT" -r "$ROOT" mark "rio-laundromat/receipts/2026/receipt-2026-06-08-home-depot \$45.23.pdf" \
    quickbooks done --ref "QBO 4411"
  [ "$status" -eq 0 ]
  side="$ROOT/rio-laundromat/receipts/2026/receipt-2026-06-08-home-depot \$45.23.json"
  [ "$(jq -r '.followups.quickbooks.status' "$side")" = "done" ]
  [ "$(jq -r '.followups.quickbooks.ref' "$side")" = "QBO 4411" ]
  run "$CAT" -r "$ROOT" pending quickbooks
  [ -z "$output" ]
}

@test "mark rejects unknown workflows and statuses" {
  run "$CAT" -r "$ROOT" mark "personal/medical/lab-results-timma-2026-06-01.pdf" fax done
  [ "$status" -eq 64 ]
  run "$CAT" -r "$ROOT" mark "personal/medical/lab-results-timma-2026-06-01.pdf" vault maybe
  [ "$status" -eq 64 ]
}

@test "dashboard injects the catalog into the template, root and per entity" {
  cat > "$TMP/tpl.html" <<'HTML'
<html><script id="catalog" type="application/json">
/*__CATALOG__*/
</script><script id="live" type="application/json">
/*__LIVE__*/
</script></html>
HTML
  echo '{ "type": "letter", "name": "letter-x", "entity": "personal", "fields": { "note": "<!--<script> </script><b>" } }' \
    > "$ROOT/personal/medical/letter-x.json"
  run env SCAN_DASHBOARD_TEMPLATE="$TMP/tpl.html" "$CAT" -r "$ROOT" dashboard
  [ "$status" -eq 0 ]
  [ -f "$ROOT/dashboard.html" ]
  [ -f "$ROOT/rio-laundromat/dashboard.html" ]
  [ -f "$ROOT/personal/dashboard.html" ]
  ! grep -q '__CATALOG__' "$ROOT/dashboard.html"
  # Static copies carry no live config; only scan-catalog serve fills it.
  [ "$(sed -n '/<script id="live"/,/<\/script>/p' "$ROOT/dashboard.html" | sed '1d;$d')" = "null" ]
  # OCR text like "<!--<script>" or "</script>" must not break the data
  # block: every "<" inside it is escaped, and the JSON still parses.
  [ "$(grep -c '</script>' "$ROOT/dashboard.html")" = "2" ]
  sed -n '/<script id="catalog"/,/<\/script>/p' "$ROOT/dashboard.html" | sed '1d;$d' > "$TMP/data.json"
  ! grep -q '<' "$TMP/data.json"
  [ "$(jq -r '.documents[] | select(.name == "letter-x") | .fields.note' "$TMP/data.json")" = "<!--<script> </script><b>" ]
  sed -n '/<script id="catalog"/,/<\/script>/p' "$ROOT/rio-laundromat/dashboard.html" | sed '1d;$d' \
    | jq -e '.scope == "rio-laundromat"' >/dev/null
}

@test "empty root builds an empty catalog" {
  run "$CAT" -r "$TMP/nothing" build
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.documents, .paychecks, .review] | map(length)' <<<"$output")" = "[0,0,0]" ]
}
