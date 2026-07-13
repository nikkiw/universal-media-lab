#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

BASE="http://127.0.0.1:${GATEWAY_PORT:-8080}"
GENERATED="$ROOT/media/generated"
CATALOG="$ROOT/media/catalog/v1/feed.json"

fail() {
  echo "verify-media: $*" >&2
  exit 1
}

[ -f "$CATALOG" ] || fail "catalog is missing; run make ingest"

asset_dir=$(find "$GENERATED" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
[ -n "$asset_dir" ] || fail "no generated assets; put a video in media/inbox and run make ingest"
id=${asset_dir##*/}

for file in \
  "$asset_dir/poster.jpg" \
  "$asset_dir/progressive/video.mp4" \
  "$asset_dir/hls/master.m3u8" \
  "$asset_dir/dash/manifest.mpd" \
  "$asset_dir/storyboard/storyboard.vtt"; do
  [ -s "$file" ] || fail "missing or empty file: $file"
done

hls_variants=$(grep -c '^#EXT-X-STREAM-INF:' "$asset_dir/hls/master.m3u8" || true)
dash_variants=$(grep -o '<Representation' "$asset_dir/dash/manifest.mpd" | wc -l | tr -d ' ')
[ "$hls_variants" -ge 1 ] || fail "HLS master has no variants"
[ "$dash_variants" -ge 1 ] || fail "DASH manifest has no representations"

if [ "$hls_variants" -lt 2 ]; then
  echo "Warning: source is too small for ABR; only one HLS rendition was generated"
fi

printf 'API catalog\n'
curl -fsS -o /dev/null "$BASE/api/v1/feed"

catalog_urls=$(
  HOST_UID=$(id -u) HOST_GID=$(id -g) \
    docker compose --profile tools run --rm --entrypoint python media-catalog \
    -c '
import json
import os
import runpy
import sys

asset_id = sys.argv[1]
catalog = json.load(open("/media/catalog/v1/feed.json", encoding="utf-8"))
item = next((candidate for candidate in catalog["items"] if candidate["id"] == asset_id), None)
if item is None:
    raise SystemExit(f"asset {asset_id!r} is missing from feed.json")

helpers = runpy.run_path("/scripts/build-catalog.py")
prefix = helpers["normalize_media_url_prefix"](os.environ.get("MEDIA_URL_PREFIX"))
media_root = f"{prefix}/{asset_id}"
expected = {
    "hlsUrl": f"{media_root}/hls/master.m3u8",
    "dashUrl": f"{media_root}/dash/manifest.mpd",
    "progressiveUrl": f"{media_root}/progressive/video.mp4",
}
for field, value in expected.items():
    if item.get(field) != value:
        raise SystemExit(f"{field} is {item.get(field)!r}; expected {value!r}")
for playback in item.get("playback", []):
    if not playback.get("url", "").startswith(f"{media_root}/"):
        raise SystemExit(f"playback URL does not use {media_root!r}: {playback!r}")
for rendition in item.get("renditions", []):
    if not rendition.get("hlsUrl", "").startswith(f"{media_root}/"):
        raise SystemExit(f"rendition URL does not use {media_root!r}: {rendition!r}")
for subtitle in item.get("subtitles", []):
    if not subtitle.get("url", "").startswith(f"{media_root}/"):
        raise SystemExit(f"subtitle URL does not use {media_root!r}: {subtitle!r}")
storyboard = item.get("storyboard")
if not storyboard or not storyboard.get("url", "").startswith(f"{media_root}/"):
    raise SystemExit("storyboard URL does not use the configured media prefix")

print(item["hlsUrl"])
print(item["dashUrl"])
print(item["progressiveUrl"])
print(storyboard["url"])
' "$id"
)
feed_hls=$(printf '%s\n' "$catalog_urls" | sed -n '1p')
feed_dash=$(printf '%s\n' "$catalog_urls" | sed -n '2p')
feed_progressive=$(printf '%s\n' "$catalog_urls" | sed -n '3p')
feed_storyboard=$(printf '%s\n' "$catalog_urls" | sed -n '4p')

printf 'Poster through imgproxy\n'
curl -fsS -o /dev/null "$BASE/img/insecure/rs:fill:320:180/q:60/plain/local:///generated/$id/poster.jpg@webp"
printf 'HLS manifest\n'
curl -fsS -o /dev/null "$BASE$feed_hls"
printf 'DASH manifest\n'
curl -fsS -o /dev/null "$BASE$feed_dash"
printf 'Storyboard track\n'
curl -fsS -o /dev/null "$BASE$feed_storyboard"
printf 'Progressive Range request\n'
status=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-1023' \
  "$BASE$feed_progressive")
[ "$status" = "206" ] || fail "expected HTTP 206 for Range request, received $status"

printf 'Local ffprobe validation\n'
HOST_UID=$(id -u) HOST_GID=$(id -g) \
  docker compose --profile tools run --rm --entrypoint ffprobe media-ingest \
  -v error -show_entries format=format_name -of default=noprint_wrappers=1:nokey=1 \
  "/media/generated/$id/hls/master.m3u8" >/dev/null
HOST_UID=$(id -u) HOST_GID=$(id -g) \
  docker compose --profile tools run --rm --entrypoint python media-catalog \
  -c "import xml.etree.ElementTree as ET; ET.parse('/media/generated/$id/dash/manifest.mpd')" >/dev/null

echo "Media verification OK: $id ($hls_variants HLS variants, $dash_variants DASH representations)"
