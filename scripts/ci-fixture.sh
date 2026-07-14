#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

mkdir -p media/inbox
rm -f media/inbox/ci-fixture.mp4
rm -rf media/generated/ci-fixture

HOST_UID=$(id -u)
HOST_GID=$(id -g)
export HOST_UID HOST_GID

echo "Generating deterministic CI media fixture"
docker compose --profile tools run --rm --entrypoint ffmpeg media-ingest \
  -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=540x960:rate=30' \
  -f lavfi -i 'sine=frequency=1000:sample_rate=48000' \
  -t 2 -shortest \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -c:a aac -b:a 96k \
  /media/inbox/ci-fixture.mp4

[ -s media/inbox/ci-fixture.mp4 ] || {
  echo "ci-fixture: generated video is missing or empty" >&2
  exit 1
}
