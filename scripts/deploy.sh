#!/usr/bin/env bash
# Deploy scan-it to its host, CT 150 "scan-it" on pve: unpack this checkout
# there next to the live copy, typecheck and run the server tests on the host
# itself, swap it in as ~/scan-it, reinstall the dashboard and tunnel user
# units (which restarts the server on the new code), then check each way in:
#
#   http://127.0.0.1:7820/                      on scan-it
#   https://macmini-2018.tail2d2c60.ts.net:8445 tailnet: tailscale serve on the
#                                               mini, reverse SSH tunnel from
#                                               the mini's 7822 to 7820
#   https://scans.beric.ca                      edge gate, then the beric-mini
#                                               Cloudflare tunnel to the mini's
#                                               7823, reverse SSH tunnel to 7821
#
# The mini's tunnel ingress and the DNS for scans.beric.ca live in the homelab
# repo (services/tunnels/mini/config.yml); this script doesn't touch them.
# Every default below can be overridden from the environment. From a canopy
# container: SCAN_DEPLOY_JUMP=mini-host SCAN_DEPLOY_MINI=mini-host.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
target=${SCAN_DEPLOY_TARGET:-eric@192.168.1.71}
jump=${SCAN_DEPLOY_JUMP:-macmini-ts}
mini=${SCAN_DEPLOY_MINI:-macmini-ts}
port=${SCAN_DEPLOY_PORT:-7820}
tailnet_url=${SCAN_DEPLOY_TAILNET_URL:-https://macmini-2018.tail2d2c60.ts.net:8445}
tailnet_login=${SCAN_DEPLOY_TAILNET_LOGIN:-baruchhub@gmail.com}
# The tunnel host as the target's ~/.ssh/config names it, and the mini's ports.
tunnel_host=${SCAN_DEPLOY_TUNNEL_HOST:-mini}
tunnel_port=${SCAN_DEPLOY_TUNNEL_PORT:-7822}
tunnel_edge_port=${SCAN_DEPLOY_TUNNEL_EDGE_PORT:-7823}
edge_url=${SCAN_DEPLOY_EDGE_URL:-https://scans.beric.ca}
# Eric, Elsa, Ariel and Jose: the family's beric.ca gate sign-ins.
edge_allow=${SCAN_DEPLOY_EDGE_ALLOW:-ericbaruch@gmail.com,elsabaruch@gmail.com,arielbaruch@gmail.com,jmjordan720@gmail.com}
edge_port=${SCAN_DEPLOY_EDGE_PORT:-7821}

say() { printf '%s\n' "$*"; }
die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }
host_of() { sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
[[ -n "$jump" ]] && ssh_opts+=(-J "$jump")
on_target() { ssh "${ssh_opts[@]}" "$target" "$@"; }
on_mini() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$mini" "$@"; }

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
rev=$(git describe --always --dirty 2>/dev/null || echo unknown)
say "== copy $rev to $target:~/scan-it.new"
tar --exclude=.git --exclude=node_modules --exclude='*.bak' -czf - . \
  | on_target "rm -rf ~/scan-it.new && mkdir ~/scan-it.new && tar -xzf - -C ~/scan-it.new && echo $rev > ~/scan-it.new/REVISION"

if [[ "${SCAN_DEPLOY_SKIP_CHECKS:-0}" != 1 ]]; then
  say "== typecheck and server tests on $target"
  on_target "cd ~/scan-it.new && bun install --silent && bun run --silent typecheck && bats test/serve.bats" \
    || die "checks failed on $target; the live copy is unchanged"
fi

say "== swap it in and reinstall the user units"
on_target "rm -rf ~/scan-it.old && { [ ! -d ~/scan-it ] || mv ~/scan-it ~/scan-it.old; } && mv ~/scan-it.new ~/scan-it \
  && mkdir -p ~/bin && for f in ~/scan-it/bin/*; do ln -sf \"\$f\" ~/bin/; done"
on_target "bash -lc '~/scan-it/bin/scan-catalog serve --install --port $port \
  --public-url $tailnet_url --allow-login $tailnet_login \
  --edge-url $edge_url --edge-allow $edge_allow --edge-port $edge_port \
  --tunnel $tunnel_host --tunnel-map $port:$tunnel_port --tunnel-map $edge_port:$tunnel_edge_port'" </dev/null

say "== check each way in"
fail=0
edge_host=$(host_of "$edge_url")
first_allow=${edge_allow%%,*}

edge_ping() {
  on_target "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $edge_host' -H 'X-Gate-User: $first_allow' http://127.0.0.1:$edge_port/api/ping" </dev/null 2>/dev/null || true
}
if got=$(wait_200 10 edge_ping); then
  say "ok    edge listener 127.0.0.1:$edge_port on $target answers for $first_allow"
else
  say "FAIL  edge listener 127.0.0.1:$edge_port on $target answered ${got:-nothing}"; fail=1
fi
got=$(on_target "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $edge_host' http://127.0.0.1:$edge_port/api/ping" </dev/null 2>/dev/null || true)
if [[ "$got" == 403 ]]; then
  say "ok    edge listener refuses a request with no X-Gate-User"
else
  say "FAIL  edge listener answered ${got:-nothing} with no X-Gate-User (want 403)"; fail=1
fi

tailnet_host=$(host_of "$tailnet_url")
first_login=${tailnet_login%%,*}
mini_ping() {
  on_mini "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $tailnet_host' -H 'Tailscale-User-Login: $first_login' http://127.0.0.1:$tunnel_port/api/ping" </dev/null 2>/dev/null || true
}
if got=$(wait_200 30 mini_ping); then
  say "ok    reverse tunnel: $mini 127.0.0.1:$tunnel_port reaches $target"
else
  say "FAIL  reverse tunnel: $mini 127.0.0.1:$tunnel_port answered ${got:-nothing} (log on $target: journalctl --user -u scan-it-tunnel)"; fail=1
fi
edge_tunnel_ping() {
  on_mini "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: $edge_host' -H 'X-Gate-User: $first_allow' http://127.0.0.1:$tunnel_edge_port/api/ping" </dev/null 2>/dev/null || true
}
if got=$(wait_200 10 edge_tunnel_ping); then
  say "ok    reverse tunnel: $mini 127.0.0.1:$tunnel_edge_port reaches the edge listener"
else
  say "FAIL  reverse tunnel: $mini 127.0.0.1:$tunnel_edge_port answered ${got:-nothing}"; fail=1
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
say "Deployed $rev to $target. Open $edge_url (beric.ca sign-in: $edge_allow) or $tailnet_url (tailnet)."
