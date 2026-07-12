#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
cat <<EOF
Desktop / browser:
  direct      http://127.0.0.1:${GATEWAY_PORT:-8080}
  dynamic     http://127.0.0.1:${NETWORK_DYNAMIC_PORT:-18080}
  clean       http://127.0.0.1:${NETWORK_CLEAN_PORT:-18081}
  wifi        http://127.0.0.1:${NETWORK_WIFI_PORT:-18082}
  lte         http://127.0.0.1:${NETWORK_LTE_PORT:-18083}
  slow-lte    http://127.0.0.1:${NETWORK_SLOW_LTE_PORT:-18084}
  3g          http://127.0.0.1:${NETWORK_3G_PORT:-18085}
  edge        http://127.0.0.1:${NETWORK_EDGE_PORT:-18086}
  flaky       http://127.0.0.1:${NETWORK_FLAKY_PORT:-18087}
  offline     http://127.0.0.1:${NETWORK_OFFLINE_PORT:-18088}

Android emulator: replace 127.0.0.1 with 10.0.2.2.
Physical Android over USB:
  adb reverse tcp:${GATEWAY_PORT:-8080} tcp:${GATEWAY_PORT:-8080}
  adb reverse tcp:${NETWORK_DYNAMIC_PORT:-18080} tcp:${NETWORK_DYNAMIC_PORT:-18080}
Then use 127.0.0.1 from the device.
EOF
