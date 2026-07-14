#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

BASE="http://127.0.0.1:${GATEWAY_PORT:-8080}"
DYN="http://127.0.0.1:${NETWORK_DYNAMIC_PORT:-18080}"

fail() {
  echo "smoke-test: $*" >&2
  exit 1
}

check_status() {
  expected=$1
  url=$2
  actual=$(curl -sS -o /dev/null -w '%{http_code}' "$url")
  [ "$actual" = "$expected" ] || fail "expected HTTP $expected from $url, received $actual"
}

assert_min_seconds() {
  value=$1
  minimum=$2
  label=$3
  awk -v value="$value" -v minimum="$minimum" 'BEGIN { exit !(value + 0 >= minimum + 0) }' ||
    fail "$label was ${value}s; expected at least ${minimum}s"
}

printf 'Health\n'
curl -fsS "$BASE/health" >/dev/null

printf 'API catalog\n'
curl -fsS -o /dev/null "$BASE/api/v1/feed"

printf 'Image\n'
curl -fsS -o /dev/null "$BASE/img/insecure/rs:fill:320:180/q:60/plain/local:///sample.jpg@webp"

printf 'Range request\n'
range_status=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-1023' \
  "$BASE/media/video/sample-portrait.mp4")
[ "$range_status" = "206" ] || fail "expected HTTP 206 for Range request, received $range_status"

printf 'WireMock delayed image\n'
ttfb=$(curl -fsS -o /dev/null -w '%{time_starttransfer}' \
  "$BASE/mock/ttfb/200/media/images/sample.jpg")
assert_min_seconds "$ttfb" 0.15 "200 ms TTFB route"

printf 'WireMock status route\n'
check_status 503 "$BASE/mock/status/503"

printf 'Toxiproxy dynamic\n'
curl -fsS -o /dev/null "$DYN/media/images/sample.jpg"

printf 'OK\n'
