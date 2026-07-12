#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
API="http://127.0.0.1:${GATEWAY_PORT:-8080}/__wiremock/settings"
PROFILE=${1:-}
case "$PROFILE" in
  clean) BODY='{"fixedDelay":0}' ;;
  ttfb-200) BODY='{"fixedDelay":200}' ;;
  ttfb-500) BODY='{"fixedDelay":500}' ;;
  ttfb-1000) BODY='{"fixedDelay":1000}' ;;
  jitter) BODY='{"delayDistribution":{"type":"uniform","lower":50,"upper":300}}' ;;
  long-tail) BODY='{"delayDistribution":{"type":"lognormal","median":150,"sigma":0.8,"maxValue":3000}}' ;;
  *) echo "Usage: $0 clean|ttfb-200|ttfb-500|ttfb-1000|jitter|long-tail"; exit 2 ;;
esac
curl -fsS -X POST "$API" -H 'Content-Type: application/json' -d "$BODY" >/dev/null
echo "WireMock global server profile: $PROFILE"
