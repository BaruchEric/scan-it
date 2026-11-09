#!/usr/bin/env bash
# Render share/dashboard.html with the sample catalog, for previewing the
# dashboard without running scan-catalog. Uses the same injection the
# generator uses: escape every "<" in the JSON as <, swap the catalog
# marker line for it, and swap the live marker line for null (a static copy).
#
#   test/render-dashboard.sh [-o OUT.html] [--entity SLUG] [--empty] [--catalog FILE] [--live FILE]
#
#   -o, --out FILE     output path (default: $TMPDIR/scan-dashboard/dashboard.html)
#   --entity SLUG      per-entity copy: keep only SLUG's documents and paychecks,
#                      set scope to SLUG, make file paths relative to the entity
#                      folder, drop review items (the same shape scan-catalog
#                      build --entity produces)
#   --empty            empty catalog: every array emptied, as on a brand-new root
#   --catalog FILE     catalog JSON to render (default: test/fixtures/catalog.sample.json)
#   --live FILE        live config JSON to inject instead of null, as scan-catalog
#                      serve does; without its server the page shows the stopped banner
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

out="${TMPDIR:-/tmp}/scan-dashboard/dashboard.html"
entity=""
empty=0
catalog="test/fixtures/catalog.sample.json"
live=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) out="$2"; shift 2 ;;
    --entity) entity="$2"; shift 2 ;;
    --empty) empty=1; shift ;;
    --catalog) catalog="$2"; shift 2 ;;
    --live) live="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "render-dashboard: unknown argument: $1" >&2; exit 64 ;;
  esac
done

template="share/dashboard.html"
for marker in '/*__CATALOG__*/' '/*__LIVE__*/'; do
  n=$(grep -cF "$marker" "$template" || true)
  if [ "$n" != "1" ]; then
    echo "render-dashboard: expected $marker exactly once in $template, found $n" >&2
    exit 1
  fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ "$empty" = 1 ]; then
  jq '.documents = [] | .paychecks = [] | .review = [] | .entities = [] | .users = [] | .scanners = []' "$catalog" > "$tmp/in.json"
elif [ -n "$entity" ]; then
  jq --arg e "$entity" '
    if any(.entities[]; .slug == $e) then . else error("no entity \($e) in catalog") end
    | .scope = $e
    | .link_prefix = ""
    | .entities = [.entities[] | select(.slug == $e)]
    | .documents = [.documents[] | select(.entity == $e) | .file |= ltrimstr($e + "/")]
    | .paychecks = [.paychecks[] | select(.entity == $e) | .file |= ltrimstr($e + "/")]
    | .review = []
  ' "$catalog" > "$tmp/in.json"
else
  cp "$catalog" "$tmp/in.json"
fi

if [ -n "$live" ]; then
  jq -c . "$live" > "$tmp/live.in"
else
  echo null > "$tmp/live.in"
fi

mkdir -p "$(dirname "$out")"
sed 's#<#\\u003c#g' "$tmp/in.json" > "$tmp/c.json"
sed 's#<#\\u003c#g' "$tmp/live.in" > "$tmp/l.json"
awk -v f="$tmp/c.json" -v g="$tmp/l.json" '
  index($0,"/*__CATALOG__*/") { while ((getline l < f) > 0) print l; next }
  index($0,"/*__LIVE__*/")    { while ((getline l < g) > 0) print l; next }
  { print }' "$template" > "$out"
echo "$out"
