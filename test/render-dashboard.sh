#!/usr/bin/env bash
# Render share/dashboard.html with the sample catalog, for previewing the
# dashboard without running scan-catalog. Uses the same injection the
# generator uses: escape "</" in the JSON, then swap the marker line for it.
#
#   test/render-dashboard.sh [-o OUT.html] [--entity SLUG] [--empty] [--catalog FILE]
#
#   -o, --out FILE     output path (default: $TMPDIR/scan-dashboard/dashboard.html)
#   --entity SLUG      per-entity copy: keep only SLUG's documents, paychecks and
#                      documents and paychecks, set scope to SLUG, make file paths
#                      relative to the entity folder, drop review items (the
#                      same shape scan-catalog build --entity produces)
#   --empty            empty catalog: every array emptied, as on a brand-new root
#   --catalog FILE     catalog JSON to render (default: test/fixtures/catalog.sample.json)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

out="${TMPDIR:-/tmp}/scan-dashboard/dashboard.html"
entity=""
empty=0
catalog="test/fixtures/catalog.sample.json"

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) out="$2"; shift 2 ;;
    --entity) entity="$2"; shift 2 ;;
    --empty) empty=1; shift ;;
    --catalog) catalog="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "render-dashboard: unknown argument: $1" >&2; exit 64 ;;
  esac
done

template="share/dashboard.html"
marker='/*__CATALOG__*/'
n=$(grep -cF "$marker" "$template" || true)
if [ "$n" != "1" ]; then
  echo "render-dashboard: expected the catalog marker exactly once in $template, found $n" >&2
  exit 1
fi

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

mkdir -p "$(dirname "$out")"
sed 's#<#\\u003c#g' "$tmp/in.json" > "$tmp/c.json"
awk -v f="$tmp/c.json" 'index($0,"/*__CATALOG__*/"){while((getline l < f)>0) print l; next} {print}' "$template" > "$out"
echo "$out"
