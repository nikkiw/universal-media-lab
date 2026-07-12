#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
API="http://127.0.0.1:${TOXIPROXY_API_PORT:-8474}"
PROXY=dynamic
PROFILE=${1:-}

usage() {
  echo "Usage: $0 clean|wifi|lte|slow-lte|3g|edge|flaky|offline|timeout|reset-peer|status"
  exit 2
}
[ -n "$PROFILE" ] || usage

remove_toxics() {
  for t in latency_up latency_down bandwidth_down packet_loss_down timeout_down reset_down; do
    curl -fsS -X DELETE "$API/proxies/$PROXY/toxics/$t" >/dev/null 2>&1 || true
  done
  curl -fsS -X POST "$API/proxies/$PROXY" -H 'Content-Type: application/json' -d '{"enabled":true}' >/dev/null
}
add_latency() {
  half=$1; jitter=$2
  curl -fsS -X POST "$API/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d "{\"name\":\"latency_up\",\"type\":\"latency\",\"stream\":\"upstream\",\"attributes\":{\"latency\":$half,\"jitter\":$jitter}}" >/dev/null
  curl -fsS -X POST "$API/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d "{\"name\":\"latency_down\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":$half,\"jitter\":$jitter}}" >/dev/null
}
add_bandwidth() {
  curl -fsS -X POST "$API/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d "{\"name\":\"bandwidth_down\",\"type\":\"bandwidth\",\"stream\":\"downstream\",\"attributes\":{\"rate\":$1}}" >/dev/null
}

case "$PROFILE" in
  status) curl -fsS "$API/proxies/$PROXY"; echo; exit 0 ;;
  clean) remove_toxics ;;
  wifi) remove_toxics; add_latency 10 3; add_bandwidth 6250 ;;
  lte) remove_toxics; add_latency 40 10; add_bandwidth 1250 ;;
  slow-lte) remove_toxics; add_latency 75 25; add_bandwidth 250 ;;
  3g) remove_toxics; add_latency 150 50; add_bandwidth 94 ;;
  edge) remove_toxics; add_latency 250 100; add_bandwidth 25 ;;
  flaky)
    remove_toxics; add_latency 200 100; add_bandwidth 125
    curl -fsS -X POST "$API/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d '{"name":"packet_loss_down","type":"packet_loss","stream":"downstream","attributes":{"loss_rate":0.05,"correlation":0.30}}' >/dev/null
    ;;
  offline)
    remove_toxics
    curl -fsS -X POST "$API/proxies/$PROXY" -H 'Content-Type: application/json' -d '{"enabled":false}' >/dev/null
    ;;
  timeout)
    remove_toxics
    curl -fsS -X POST "$API/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d '{"name":"timeout_down","type":"timeout","stream":"downstream","attributes":{"timeout":0}}' >/dev/null
    ;;
  reset-peer)
    remove_toxics
    curl -fsS -X POST "$API/proxies/$PROXY/toxics" -H 'Content-Type: application/json' -d '{"name":"reset_down","type":"reset_peer","stream":"downstream","attributes":{"timeout":500}}' >/dev/null
    ;;
  *) usage ;;
esac

echo "Dynamic network profile: $PROFILE"
echo "Client base URL: http://<host>:${NETWORK_DYNAMIC_PORT:-18080}"
