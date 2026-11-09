#!/usr/bin/env bash
# Deploy the live dashboard from this checkout: typecheck, run the server
# tests, reinstall both LaunchAgents (which restarts the server on the code
# here), then check each way in:
#
#   http://127.0.0.1:7820/                      this Mac
#   https://macmini-2018.tail2d2c60.ts.net:8445 tailnet: tailscale serve on the
#                                               mini, reverse SSH tunnel to 7820
#   https://scans.beric.ca                      edge gate, then the beric-mac
#                                               Cloudflare tunnel to 7821
#
# The tunnel ingress and DNS for scans.beric.ca live in the homelab repo
# (services/tunnels/mac/config.yml); this script doesn't touch them.
# Every default below can be overridden from the environment.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
port=${SCAN_DEPLOY_PORT:-7820}
tailnet_url=${SCAN_DEPLOY_TAILNET_URL:-https://macmini-2018.tail2d2c60.ts.net:8445}
tailnet_login=${SCAN_DEPLOY_TAILNET_LOGIN:-baruchhub@gmail.com}
tunnel_host=${SCAN_DEPLOY_TUNNEL_HOST:-macmini-ts}
edge_url=${SCAN_DEPLOY_EDGE_URL:-https://scans.beric.ca}
# Eric, Elsa, Ariel and Jose: the family's beric.ca gate sign-ins.
edge_allow=${SCAN_DEPLOY_EDGE_ALLOW:-ericbaruch@gmail.com,elsabaruch@gmail.com,arielbaruch@gmail.com,jmjordan720@gmail.com}
edge_port=${SCAN_DEPLOY_EDGE_PORT:-7821}

say() { printf '%s\n' "$*"; }
die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }
host_of() { sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }

# Poll until the command prints 200, for up to $1 seconds.
wait_200() {
  local secs="$1"; shift
  local got=""
  for _ in $(seq 1 "$secs"); do
    got=$("$@")
    [[ "$got" == 200 ]] && return 0
    sleep 1
  done
  printf '%s' "$got"
  return 1
}

cd "$here"
if [[ "${SCAN_DEPLOY_SKIP_CHECKS:-0}" != 1 ]]; then
  say "== typecheck and server tests"
  [[ -d node_modules ]] || bun install --silent
  bun run --silent typecheck
  bats test/serve.bats
fi

say "== install the LaunchAgents"
bin/scan-catalog serve --install --port "$port" \
  --public-url "$tailnet_url" --allow-login "$tailnet_login" \
  --edge-url "$edge_url" --edge-allow "$edge_allow" --edge-port "$edge_port" \
  --tunnel "$tunnel_host"

say "== check each way in"
fail=0
edge_host=$(host_of "$edge_url")
first_allow=${edge_allow%%,*}

edge_ping() {
  code -H "Host: $edge_host" -H "X-Gate-User: $first_allow" "http://127.0.0.1:$edge_port/api/ping"
}
if got=$(wait_200 10 edge_ping); then
  say "ok    edge listener 127.0.0.1:$edge_port answers for $first_allow"
else
  say "FAIL  edge listener 127.0.0.1:$edge_port answered ${got:-nothing}"; fail=1
fi
got=$(code -H "Host: $edge_host" "http://127.0.0.1:$edge_port/api/ping")
if [[ "$got" == 403 ]]; then
  say "ok    edge listener refuses a request with no X-Gate-User"
else
  say "FAIL  edge listener answered $got with no X-Gate-User (want 403)"; fail=1
fi

tailnet_host=$(host_of "$tailnet_url")
first_login=${tailnet_login%%,*}
mini_ping() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$tunnel_host" \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $tailnet_host' -H 'Tailscale-User-Login: $first_login' http://127.0.0.1:$port/api/ping" 2>/dev/null || true
}
if got=$(wait_200 30 mini_ping); then
  say "ok    reverse tunnel: $tunnel_host 127.0.0.1:$port reaches this Mac"
else
  say "FAIL  reverse tunnel: $tunnel_host 127.0.0.1:$port answered ${got:-nothing} (log: ~/Library/Logs/scan-it-tunnel.log)"; fail=1
fi

# Signed out, the edge gate must answer before the app does. Its 401 comes
# before the origin is tried, so this can't see a missing tunnel route: a
# signed-in browser gets 526 for that, and 404 for a missing ingress rule.
got=$(code -H 'Accept: application/json' "${edge_url%/}/api/ping")
case "$got" in
  401|403) say "ok    $edge_url is behind the edge gate ($got signed out)" ;;
  200) say "FAIL  $edge_url answered 200 signed out: the edge gate is not in front"; fail=1 ;;
  *) say "FAIL  $edge_url answered ${got:-nothing} signed out (want 401)"; fail=1 ;;
esac

(( fail == 0 )) || die "some checks failed"
say "Deployed. Open $edge_url (beric.ca sign-in: $edge_allow) or $tailnet_url (tailnet)."
