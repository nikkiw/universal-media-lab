#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
BASE="http://127.0.0.1:${GATEWAY_PORT:-8080}"
DYN="http://127.0.0.1:${NETWORK_DYNAMIC_PORT:-18080}"

echo "Health"
curl -fsS "$BASE/health"
echo "Image"
curl -fsS -o /dev/null "$BASE/img/insecure/rs:fill:320:180/q:60/plain/local:///sample.jpg@webp"
echo "Range request"
curl -fsS -H 'Range: bytes=0-1023' -o /dev/null "$BASE/media/video/sample-portrait.mp4"
echo "WireMock delayed image"
curl -fsS -o /dev/null "$BASE/mock/ttfb/200/media/images/sample.jpg"
echo "Toxiproxy dynamic"
curl -fsS -o /dev/null "$DYN/media/images/sample.jpg"
echo "OK"
