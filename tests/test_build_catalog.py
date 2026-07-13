from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "build-catalog.py"
SPEC = importlib.util.spec_from_file_location("build_catalog", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
build_catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_catalog)


class BuildCatalogTest(unittest.TestCase):
    def create_asset(self, generated_root: Path, asset_id: str = "demo") -> Path:
        asset_dir = generated_root / asset_id
        files = {
            "probe.json": json.dumps(
                {
                    "streams": [
                        {
                            "codec_type": "video",
                            "codec_name": "hevc",
                            "width": 1920,
                            "height": 1080,
                        },
                        {"codec_type": "audio", "codec_name": "opus"},
                    ],
                    "format": {"duration": "12.5"},
                }
            ),
            "output-probe.json": json.dumps(
                {
                    "streams": [
                        {
                            "codec_type": "video",
                            "codec_name": "h264",
                            "width": 540,
                            "height": 960,
                        },
                        {"codec_type": "audio", "codec_name": "aac"},
                    ]
                }
            ),
            "renditions.tsv": (
                "360p\t360\t640\t500000\t650000\n"
                "540p\t540\t960\t1100000\t1400000\n"
            ),
            "poster.jpg": "poster",
            "progressive/video.mp4": "video",
            "hls/master.m3u8": "#EXTM3U\n",
            "dash/manifest.mpd": "<MPD/>\n",
            "storyboard/frame-00001.jpg": "frame",
            "subtitles/en.vtt": "WEBVTT\n",
            ".source-name": "Demo Source.mov\n",
            ".poster.rgb24": bytes([255, 0, 0] * 1024),
            ".poster.lqip": "UklGRq4AAABXRUJQVlA4...",
        }
        for relative_path, contents in files.items():
            path = asset_dir / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(contents, bytes):
                path.write_bytes(contents)
            else:
                path.write_text(contents, encoding="utf-8")
        return asset_dir

    def test_normalizes_media_url_prefix(self) -> None:
        cases = {
            None: "/media/generated",
            "": "/media/generated",
            " /videos/ ": "/videos",
            "/nested//videos///": "/nested/videos",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(
                    build_catalog.normalize_media_url_prefix(value), expected
                )

    def test_rejects_invalid_media_url_prefix(self) -> None:
        invalid_values = [
            "videos",
            "/",
            "//cdn.example/media",
            "https://cdn.example/media",
            "/videos?token=value",
            "/videos#fragment",
            "/videos/../private",
            "/videos/%2e%2e/private",
            "/video path",
            "/video%20path",
            "/videos\\private",
        ]
        for value in invalid_values:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    build_catalog.normalize_media_url_prefix(value)

    def test_custom_prefix_updates_public_urls_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            asset_dir = self.create_asset(Path(temporary_directory))
            asset = build_catalog.build_asset(asset_dir, "/videos")

            self.assertIsNotNone(asset)
            assert asset is not None
            self.assertEqual(asset["width"], 540)
            self.assertEqual(asset["height"], 960)
            self.assertEqual(asset["orientation"], "portrait")
            self.assertEqual(asset["hlsUrl"], "/videos/demo/hls/master.m3u8")
            self.assertEqual(asset["dashUrl"], "/videos/demo/dash/manifest.mpd")
            self.assertEqual(
                asset["progressiveUrl"], "/videos/demo/progressive/video.mp4"
            )
            self.assertTrue(
                all(
                    playback["url"].startswith("/videos/demo/")
                    for playback in asset["playback"]
                )
            )
            self.assertTrue(
                all(
                    rendition["hlsUrl"].startswith("/videos/demo/")
                    for rendition in asset["renditions"]
                )
            )
            self.assertEqual(
                asset["subtitles"][0]["url"], "/videos/demo/subtitles/en.vtt"
            )
            self.assertEqual(
                asset["storyboard"]["url"],
                "/videos/demo/storyboard/storyboard.vtt",
            )
            self.assertEqual(asset["apiUrl"], "/api/v1/media/demo")
            self.assertTrue(asset["posterUrl"].startswith("/img/"))
            self.assertEqual(
                asset["testUrls"]["cacheableProgressive"],
                "/cache/media/generated/demo/progressive/video.mp4",
            )
            self.assertEqual(
                asset["testUrls"]["ttfb1000Progressive"],
                "/mock/ttfb/1000/media/generated/demo/progressive/video.mp4",
            )

    def test_legacy_asset_uses_largest_rendition_for_output_dimensions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            asset_dir = self.create_asset(Path(temporary_directory))
            (asset_dir / "output-probe.json").unlink()

            asset = build_catalog.build_asset(asset_dir, "/media/generated")

            self.assertIsNotNone(asset)
            assert asset is not None
            self.assertEqual(asset["width"], 540)
            self.assertEqual(asset["height"], 960)
            self.assertEqual(asset["orientation"], "portrait")

    def test_main_writes_custom_urls_to_feed_and_asset_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            media_root = Path(temporary_directory)
            generated_root = media_root / "generated"
            catalog_root = media_root / "catalog" / "v1"
            self.create_asset(generated_root)

            with (
                mock.patch.object(build_catalog, "GENERATED_ROOT", generated_root),
                mock.patch.object(build_catalog, "CATALOG_ROOT", catalog_root),
                mock.patch.dict(os.environ, {"MEDIA_URL_PREFIX": "/nested/videos/"}),
            ):
                self.assertEqual(build_catalog.main(), 0)

            feed = json.loads(
                (catalog_root / "feed.json").read_text(encoding="utf-8")
            )
            asset = json.loads(
                (catalog_root / "media" / "demo.json").read_text(encoding="utf-8")
            )
            expected_hls_url = "/nested/videos/demo/hls/master.m3u8"
            self.assertEqual(feed["items"][0]["hlsUrl"], expected_hls_url)
            self.assertEqual(asset["hlsUrl"], expected_hls_url)

    def test_placeholder_blurhash(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary_directory,
            mock.patch.object(build_catalog, "PLACEHOLDER_ALGORITHM", "blurhash")
        ):
            asset_dir = self.create_asset(Path(temporary_directory))
            asset = build_catalog.build_asset(asset_dir, "/media/generated")
            self.assertIsNotNone(asset)
            assert asset is not None
            self.assertEqual(asset["placeholder"]["type"], "blurhash")
            self.assertEqual(asset["placeholder"]["value"], "U9TI:j|cfQ|c|co1fQo1fQfQfQfQ|co1fQo1")
            self.assertEqual(asset["blurhash"], "U9TI:j|cfQ|c|co1fQo1fQfQfQfQ|co1fQo1")

    def test_placeholder_thumbhash(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary_directory,
            mock.patch.object(build_catalog, "PLACEHOLDER_ALGORITHM", "thumbhash")
        ):
            asset_dir = self.create_asset(Path(temporary_directory))
            asset = build_catalog.build_asset(asset_dir, "/media/generated")
            self.assertIsNotNone(asset)
            assert asset is not None
            self.assertEqual(asset["placeholder"]["type"], "thumbhash")
            self.assertTrue(len(asset["placeholder"]["value"]) > 0)
            self.assertEqual(asset["thumbhash"], asset["placeholder"]["value"])

    def test_placeholder_lqip(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary_directory,
            mock.patch.object(build_catalog, "PLACEHOLDER_ALGORITHM", "lqip")
        ):
            asset_dir = self.create_asset(Path(temporary_directory))
            asset = build_catalog.build_asset(asset_dir, "/media/generated")
            self.assertIsNotNone(asset)
            assert asset is not None
            self.assertEqual(asset["placeholder"]["type"], "lqip")
            self.assertEqual(asset["placeholder"]["value"], "data:image/webp;base64,UklGRq4AAABXRUJQVlA4...")
            self.assertEqual(asset["lqip"], "data:image/webp;base64,UklGRq4AAABXRUJQVlA4...")

    def test_placeholder_average_color(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary_directory,
            mock.patch.object(build_catalog, "PLACEHOLDER_ALGORITHM", "average_color")
        ):
            asset_dir = self.create_asset(Path(temporary_directory))
            asset = build_catalog.build_asset(asset_dir, "/media/generated")
            self.assertIsNotNone(asset)
            assert asset is not None
            self.assertEqual(asset["placeholder"]["type"], "average_color")
            self.assertEqual(asset["placeholder"]["value"], "#ff0000")
            self.assertEqual(asset["averageColor"], "#ff0000")


if __name__ == "__main__":
    unittest.main()
