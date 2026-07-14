#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

BASE="http://127.0.0.1:${GATEWAY_PORT:-8080}"
DYN="http://127.0.0.1:${NETWORK_DYNAMIC_PORT:-18080}"
TOXI="http://127.0.0.1:${TOXIPROXY_API_PORT:-8474}"

fail() {
  echo "e2e-test: $*" >&2
  exit 1
}

cleanup() {
  "$ROOT/scripts/network-profile.sh" clean >/dev/null 2>&1 || true
  "$ROOT/scripts/server-profile.sh" clean >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_for_url() {
  name=$1
  url=$2
  attempts=${3:-60}
  i=1
  while [ "$i" -le "$attempts" ]; do
    if curl -fsS --max-time 2 -o /dev/null "$url"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  fail "$name did not become ready: $url"
}

assert_proxy_contains() {
  proxy=$1
  needle=$2
  body=$(curl -fsS "$TOXI/proxies/$proxy")
  printf '%s' "$body" | grep -Fq "$needle" || fail "proxy $proxy does not contain $needle: $body"
}

assert_dynamic_toxics() {
  profile=$1
  shift
  "$ROOT/scripts/network-profile.sh" "$profile" >/dev/null
  body=$(curl -fsS "$TOXI/proxies/dynamic")
  for needle in "$@"; do
    printf '%s' "$body" | grep -Fq "$needle" || fail "dynamic profile $profile does not contain $needle: $body"
  done
}

expect_request_failure() {
  label=$1
  timeout=$2
  url=$3
  if curl -fsS --max-time "$timeout" -o /dev/null "$url" 2>/dev/null; then
    fail "$label unexpectedly succeeded"
  fi
}

measure_ttfb() {
  profile=$1
  minimum=$2
  "$ROOT/scripts/server-profile.sh" "$profile" >/dev/null
  value=$(curl -sS -o /dev/null -w '%{time_starttransfer}' "$BASE/mock/status/503")
  awk -v actual="$value" -v minimum="$minimum" 'BEGIN { exit !(actual >= minimum) }' || \
    fail "$profile TTFB was ${value}s, expected at least ${minimum}s"
  echo "$profile TTFB: ${value}s"
}

echo "Waiting for runtime services"
wait_for_url "gateway" "$BASE/health"
wait_for_url "Toxiproxy API" "$TOXI/version"

# The bootstrap container is one-shot. Poll its observable result rather than
# merely checking that the Toxiproxy daemon itself is alive.
i=1
while [ "$i" -le 60 ]; do
  if body=$(curl -fsS "$TOXI/proxies/flaky" 2>/dev/null) && \
     printf '%s' "$body" | grep -Fq '"name":"flaky_reset_down"'; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
[ "$i" -le 60 ] || fail "Toxiproxy bootstrap did not configure the static flaky profile"

all_proxies=$(curl -fsS "$TOXI/proxies")
if printf '%s' "$all_proxies" | grep -Fq '"type":"packet_loss"'; then
  fail "unsupported packet_loss toxic is still configured"
fi

# Verify every stable network preset was populated with its expected released
# Toxiproxy v2.12-compatible toxics.
for proxy in wifi lte slow_lte three_g edge flaky; do
  assert_proxy_contains "$proxy" '"name":"latency_up"'
  assert_proxy_contains "$proxy" '"name":"latency_down"'
  assert_proxy_contains "$proxy" '"name":"bandwidth_down"'
done
assert_proxy_contains flaky '"name":"flaky_reset_down"'
assert_proxy_contains flaky '"type":"reset_peer"'

# Fast functional smoke test against the live stack.
"$ROOT/scripts/smoke-test.sh"

# Every dynamic profile must be accepted by the pinned Toxiproxy release.
assert_dynamic_toxics clean '"enabled":true'
assert_dynamic_toxics wifi '"name":"latency_up"' '"name":"latency_down"' '"name":"bandwidth_down"'
assert_dynamic_toxics lte '"name":"latency_up"' '"name":"latency_down"' '"name":"bandwidth_down"'
assert_dynamic_toxics slow-lte '"name":"latency_up"' '"name":"latency_down"' '"name":"bandwidth_down"'
assert_dynamic_toxics 3g '"name":"latency_up"' '"name":"latency_down"' '"name":"bandwidth_down"'
assert_dynamic_toxics edge '"name":"latency_up"' '"name":"latency_down"' '"name":"bandwidth_down"'
assert_dynamic_toxics flaky '"name":"flaky_reset_down"' '"type":"reset_peer"' '"toxicity":0.05'

"$ROOT/scripts/network-profile.sh" clean >/dev/null
curl -fsS --max-time 5 -o /dev/null "$DYN/media/images/sample.jpg"

"$ROOT/scripts/network-profile.sh" offline >/dev/null
expect_request_failure "offline profile" 2 "$DYN/health"

"$ROOT/scripts/network-profile.sh" timeout >/dev/null
expect_request_failure "timeout profile" 1 "$DYN/media/images/sample.jpg"

"$ROOT/scripts/network-profile.sh" reset-peer >/dev/null
expect_request_failure "reset-peer profile" 3 "$DYN/mock/body/5000/media/video/sample-portrait.mp4"

"$ROOT/scripts/network-profile.sh" clean >/dev/null

# Deterministic HTTP status mappings.
for status in 404 429 500 503; do
  actual=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/mock/status/$status")
  [ "$actual" = "$status" ] || fail "expected HTTP $status, received $actual"
done

# Global server profiles must be accepted and fixed-delay profiles must affect
# observed time-to-first-byte, not just mutate WireMock settings successfully.
"$ROOT/scripts/server-profile.sh" clean >/dev/null
measure_ttfb ttfb-200 0.15
measure_ttfb ttfb-500 0.45
measure_ttfb ttfb-1000 0.90

for profile in jitter long-tail; do
  "$ROOT/scripts/server-profile.sh" "$profile" >/dev/null
  actual=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/mock/status/503")
  [ "$actual" = "503" ] || fail "$profile profile changed expected HTTP status: $actual"
done

"$ROOT/scripts/server-profile.sh" clean >/dev/null
"$ROOT/scripts/network-profile.sh" clean >/dev/null

echo "Runtime E2E verification OK"
