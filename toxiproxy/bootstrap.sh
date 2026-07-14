#!/bin/sh
set -eu

API="http://toxiproxy:8474"
until curl -fsS "$API/version" >/dev/null 2>&1; do sleep 1; done

curl -fsS -X POST "$API/populate" -H 'Content-Type: application/json' -d '[
  {"name":"dynamic","listen":"0.0.0.0:18080","upstream":"gateway:8080","enabled":true},
  {"name":"clean","listen":"0.0.0.0:18081","upstream":"gateway:8080","enabled":true},
  {"name":"wifi","listen":"0.0.0.0:18082","upstream":"gateway:8080","enabled":true},
  {"name":"lte","listen":"0.0.0.0:18083","upstream":"gateway:8080","enabled":true},
  {"name":"slow_lte","listen":"0.0.0.0:18084","upstream":"gateway:8080","enabled":true},
  {"name":"three_g","listen":"0.0.0.0:18085","upstream":"gateway:8080","enabled":true},
  {"name":"edge","listen":"0.0.0.0:18086","upstream":"gateway:8080","enabled":true},
  {"name":"flaky","listen":"0.0.0.0:18087","upstream":"gateway:8080","enabled":true},
  {"name":"offline","listen":"0.0.0.0:18088","upstream":"gateway:8080","enabled":true}
]' >/dev/null

# Remove previous toxics while keeping all proxies. packet_loss_down is included
# only to clean stale state from development images that exposed that toxic.
for p in dynamic clean wifi lte slow_lte three_g edge flaky offline; do
  for t in latency_up latency_down bandwidth_down packet_loss_down flaky_reset_down timeout_down reset_down; do
    curl -fsS -X DELETE "$API/proxies/$p/toxics/$t" >/dev/null 2>&1 || true
  done
  curl -fsS -X POST "$API/proxies/$p" -H 'Content-Type: application/json' -d '{"enabled":true}' >/dev/null
done

add_latency() {
  proxy="$1"
  half="$2"
  jitter="$3"
  curl -fsS -X POST "$API/proxies/$proxy/toxics" -H 'Content-Type: application/json' \
    -d "{\"name\":\"latency_up\",\"type\":\"latency\",\"stream\":\"upstream\",\"attributes\":{\"latency\":$half,\"jitter\":$jitter}}" >/dev/null
  curl -fsS -X POST "$API/proxies/$proxy/toxics" -H 'Content-Type: application/json' \
    -d "{\"name\":\"latency_down\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":$half,\"jitter\":$jitter}}" >/dev/null
}

add_bandwidth() {
  proxy="$1"
  rate="$2"
  curl -fsS -X POST "$API/proxies/$proxy/toxics" -H 'Content-Type: application/json' \
    -d "{\"name\":\"bandwidth_down\",\"type\":\"bandwidth\",\"stream\":\"downstream\",\"attributes\":{\"rate\":$rate}}" >/dev/null
}

# Approximate presets. Latency is split between request and response paths;
# bandwidth is KB/s.
add_latency wifi 10 3; add_bandwidth wifi 6250
add_latency lte 40 10; add_bandwidth lte 1250
add_latency slow_lte 75 25; add_bandwidth slow_lte 250
add_latency three_g 150 50; add_bandwidth three_g 94
add_latency edge 250 100; add_bandwidth edge 25
add_latency flaky 200 100; add_bandwidth flaky 125

# Toxiproxy v2.12.0 has no packet_loss toxic. Use a 5% probability of a
# downstream TCP reset as a portable, released-version approximation of an
# intermittent flaky connection.
curl -fsS -X POST "$API/proxies/flaky/toxics" -H 'Content-Type: application/json' \
  -d '{"name":"flaky_reset_down","type":"reset_peer","stream":"downstream","toxicity":0.05,"attributes":{"timeout":500}}' >/dev/null

curl -fsS -X POST "$API/proxies/offline" -H 'Content-Type: application/json' -d '{"enabled":false}' >/dev/null

echo "Toxiproxy profiles are ready."
