#!/usr/bin/env python3
"""Build the static production-like media API from generated assets."""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

MEDIA_ROOT = Path(os.environ.get("MEDIA_ROOT", "/media"))
GENERATED_ROOT = MEDIA_ROOT / "generated"
CATALOG_ROOT = MEDIA_ROOT / "catalog" / "v1"
STORYBOARD_INTERVAL = max(1, int(os.environ.get("MEDIA_STORYBOARD_INTERVAL", "5")))
DEFAULT_MEDIA_URL_PREFIX = "/media/generated"


def warn(message: str) -> None:
    print(f"media-catalog: {message}", file=sys.stderr)


def normalize_media_url_prefix(value: str | None) -> str:
    prefix = (value or "").strip() or DEFAULT_MEDIA_URL_PREFIX
    parsed = urlsplit(prefix)
    if (
        parsed.scheme
        or parsed.netloc
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith("/")
        or parsed.path.startswith("//")
    ):
        raise ValueError("must be a root-relative URL path beginning with a single '/'")
    decoded_path = unquote(parsed.path)
    if any(character.isspace() or character == "\\" for character in decoded_path):
        raise ValueError("must not contain whitespace or backslashes")

    segments = [segment for segment in parsed.path.split("/") if segment]
    decoded_segments = [segment for segment in decoded_path.split("/") if segment]
    if not segments or any(segment in {".", ".."} for segment in decoded_segments):
        raise ValueError("must contain at least one path segment and no '.' or '..' segments")
    return "/" + "/".join(segments)


def join_url(prefix: str, *parts: str) -> str:
    return "/".join([prefix.rstrip("/"), *(part.strip("/") for part in parts)])


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object in {path}")
    return value


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent, text=True
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
        os.chmod(temporary, 0o644)
        temporary.replace(path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write_text(
        path,
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
    )


def first_stream(probe: dict[str, Any], codec_type: str) -> dict[str, Any] | None:
    streams = probe.get("streams", [])
    if not isinstance(streams, list):
        return None
    for stream in streams:
        if isinstance(stream, dict) and stream.get("codec_type") == codec_type:
            return stream
    return None


def rotation_of(stream: dict[str, Any]) -> int:
    tags = stream.get("tags")
    if isinstance(tags, dict):
        try:
            return int(float(str(tags.get("rotate", 0)))) % 360
        except ValueError:
            pass

    side_data = stream.get("side_data_list")
    if isinstance(side_data, list):
        for entry in side_data:
            if not isinstance(entry, dict) or "rotation" not in entry:
                continue
            try:
                return int(float(str(entry["rotation"]))) % 360
            except ValueError:
                continue
    return 0


def duration_seconds(probe: dict[str, Any]) -> float:
    format_data = probe.get("format")
    if isinstance(format_data, dict):
        try:
            return max(0.0, float(str(format_data.get("duration", 0))))
        except ValueError:
            pass

    maximum = 0.0
    streams = probe.get("streams", [])
    if isinstance(streams, list):
        for stream in streams:
            if not isinstance(stream, dict):
                continue
            try:
                maximum = max(maximum, float(str(stream.get("duration", 0))))
            except ValueError:
                continue
    return maximum


def parse_renditions(path: Path, media_root: str) -> list[dict[str, Any]]:
    renditions: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        columns = line.split("\t")
        if len(columns) < 4:
            raise ValueError(f"invalid rendition line in {path}: {line!r}")
        name, width, height, bitrate = columns[:4]
        renditions.append(
            {
                "name": name,
                "width": int(width),
                "height": int(height),
                "bitrate": int(bitrate),
                "hlsUrl": join_url(media_root, "hls", name, "playlist.m3u8"),
            }
        )
    return renditions


def format_vtt_time(seconds: float) -> str:
    milliseconds = max(0, int(round(seconds * 1000)))
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    secs, millis = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def build_storyboard(
    asset_dir: Path, duration: float, media_root: str
) -> dict[str, Any] | None:
    storyboard_dir = asset_dir / "storyboard"
    frames = sorted(storyboard_dir.glob("frame-*.jpg"))
    if not frames:
        return None

    cues = ["WEBVTT", ""]
    for index, frame in enumerate(frames):
        start = index * STORYBOARD_INTERVAL
        if duration > 0:
            end = min(duration, (index + 1) * STORYBOARD_INTERVAL)
        else:
            end = (index + 1) * STORYBOARD_INTERVAL
        if end <= start:
            end = start + 0.001
        cues.extend(
            [
                f"{format_vtt_time(start)} --> {format_vtt_time(end)}",
                frame.name,
                "",
            ]
        )

    vtt_path = storyboard_dir / "storyboard.vtt"
    atomic_write_text(vtt_path, "\n".join(cues))
    return {
        "url": join_url(media_root, "storyboard", "storyboard.vtt"),
        "intervalSeconds": STORYBOARD_INTERVAL,
        "frameCount": len(frames),
        "width": 320,
    }


def subtitle_language(filename: str) -> str:
    language = Path(filename).stem.lower()
    return language or "und"


def build_subtitles(asset_dir: Path, media_root: str) -> list[dict[str, str]]:
    subtitles: list[dict[str, str]] = []
    subtitle_dir = asset_dir / "subtitles"
    if not subtitle_dir.is_dir():
        return subtitles

    for subtitle in sorted(subtitle_dir.glob("*.vtt")):
        language = subtitle_language(subtitle.name)
        subtitles.append(
            {
                "language": language,
                "label": language.upper() if language != "und" else "Subtitles",
                "mimeType": "text/vtt",
                "url": join_url(media_root, "subtitles", subtitle.name),
            }
        )
    return subtitles


def build_asset(asset_dir: Path, media_url_prefix: str) -> dict[str, Any] | None:
    required = [
        asset_dir / "probe.json",
        asset_dir / "renditions.tsv",
        asset_dir / "poster.jpg",
        asset_dir / "progressive" / "video.mp4",
        asset_dir / "hls" / "master.m3u8",
        asset_dir / "dash" / "manifest.mpd",
    ]
    missing = [str(path.relative_to(asset_dir)) for path in required if not path.is_file()]
    if missing:
        warn(f"skipping incomplete asset {asset_dir.name}: missing {', '.join(missing)}")
        return None

    probe = read_json(asset_dir / "probe.json")
    source_video = first_stream(probe, "video")
    if source_video is None:
        warn(f"skipping {asset_dir.name}: probe contains no video stream")
        return None
    source_audio = first_stream(probe, "audio")

    duration = duration_seconds(probe)
    source_name_path = asset_dir / ".source-name"
    source_name = (
        source_name_path.read_text(encoding="utf-8").strip()
        if source_name_path.is_file()
        else f"{asset_dir.name}.mp4"
    )
    asset_id = asset_dir.name
    media_root = join_url(media_url_prefix, asset_id)
    internal_media_root = f"/media/generated/{asset_id}"
    imgproxy_root = f"local:///generated/{asset_id}/poster.jpg"
    renditions = parse_renditions(asset_dir / "renditions.tsv", media_root)
    if not renditions:
        warn(f"skipping {asset_id}: no renditions found")
        return None
    output_probe_path = asset_dir / "output-probe.json"
    output_probe = read_json(output_probe_path) if output_probe_path.is_file() else None
    output_video = first_stream(output_probe, "video") if output_probe is not None else None
    output_audio = first_stream(output_probe, "audio") if output_probe is not None else None
    if output_probe is not None and output_video is None:
        warn(f"skipping {asset_id}: output probe contains no video stream")
        return None
    if output_video is not None:
        width = int(output_video.get("width") or 0)
        height = int(output_video.get("height") or 0)
        rotation = rotation_of(output_video)
        if rotation in {90, 270}:
            width, height = height, width
    else:
        largest_rendition = max(
            renditions, key=lambda rendition: rendition["width"] * rendition["height"]
        )
        width = largest_rendition["width"]
        height = largest_rendition["height"]
    orientation = (
        "portrait"
        if height > width
        else "landscape"
        if width > height
        else "square"
    )
    storyboard = build_storyboard(asset_dir, duration, media_root)
    has_audio = (
        output_audio is not None
        if output_probe is not None
        else source_audio is not None
    )

    asset: dict[str, Any] = {
        "id": asset_id,
        "apiUrl": f"/api/v1/media/{asset_id}",
        "title": asset_id.replace("-", " ").title(),
        "durationMs": int(round(duration * 1000)),
        "width": width,
        "height": height,
        "orientation": orientation,
        "sourceFile": source_name,
        "hasAudio": has_audio,
        "codecs": {
            "video": "h264",
            "audio": "aac" if has_audio else None,
        },
        "sourceCodecs": {
            "video": source_video.get("codec_name"),
            "audio": source_audio.get("codec_name") if source_audio else None,
        },
        "posterUrl": f"/img/insecure/rs:fit:720:1280/q:75/plain/{imgproxy_root}@webp",
        "thumbnailUrl": f"/img/insecure/rs:fill:360:640/q:70/plain/{imgproxy_root}@webp",
        "blurredPosterUrl": f"/img/insecure/rs:fill:36:64/q:20/bl:8/plain/{imgproxy_root}@webp",
        "avifPosterUrl": f"/img/insecure/rs:fit:720:1280/q:55/plain/{imgproxy_root}@avif",
        "progressiveUrl": join_url(media_root, "progressive", "video.mp4"),
        "hlsUrl": join_url(media_root, "hls", "master.m3u8"),
        "dashUrl": join_url(media_root, "dash", "manifest.mpd"),
        "playback": [
            {
                "type": "hls",
                "mimeType": "application/vnd.apple.mpegurl",
                "url": join_url(media_root, "hls", "master.m3u8"),
            },
            {
                "type": "dash",
                "mimeType": "application/dash+xml",
                "url": join_url(media_root, "dash", "manifest.mpd"),
            },
            {
                "type": "progressive",
                "mimeType": "video/mp4",
                "url": join_url(media_root, "progressive", "video.mp4"),
            },
        ],
        "renditions": renditions,
        "subtitles": build_subtitles(asset_dir, media_root),
        "testUrls": {
            "cacheableProgressive": f"/cache{internal_media_root}/progressive/video.mp4",
            "noRangeProgressive": f"/no-range{internal_media_root}/progressive/video.mp4",
            "wrongContentTypeProgressive": f"/wrong-content-type{internal_media_root}/progressive/video.mp4",
            "ttfb1000Progressive": f"/mock/ttfb/1000{internal_media_root}/progressive/video.mp4",
            "http503": "/mock/status/503",
            "connectionReset": "/mock/fault/reset",
        },
    }
    if storyboard is not None:
        asset["storyboard"] = storyboard
    return asset


def main() -> int:
    try:
        media_url_prefix = normalize_media_url_prefix(os.environ.get("MEDIA_URL_PREFIX"))
    except ValueError as error:
        warn(f"invalid MEDIA_URL_PREFIX: {error}")
        return 2

    GENERATED_ROOT.mkdir(parents=True, exist_ok=True)
    media_catalog_dir = CATALOG_ROOT / "media"
    media_catalog_dir.mkdir(parents=True, exist_ok=True)

    assets: list[dict[str, Any]] = []
    for asset_dir in sorted(path for path in GENERATED_ROOT.iterdir() if path.is_dir()):
        asset = build_asset(asset_dir, media_url_prefix)
        if asset is None:
            continue
        assets.append(asset)
        atomic_write_json(media_catalog_dir / f"{asset['id']}.json", asset)

    current_ids = {asset["id"] for asset in assets}
    for stale in media_catalog_dir.glob("*.json"):
        if stale.stem not in current_ids:
            stale.unlink()

    feed = {
        "version": 1,
        "baseUrl": "",
        "items": assets,
    }
    atomic_write_json(CATALOG_ROOT / "feed.json", feed)
    print(f"Built media catalog with {len(assets)} asset(s): {CATALOG_ROOT / 'feed.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
