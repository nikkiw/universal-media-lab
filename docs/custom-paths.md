# Customizing Paths

Media Lab has three different kinds of paths. They are configured independently:

- host paths, such as the directory containing source videos;
- container paths, such as `/media/generated` inside the tool containers;
- public URL paths written to the generated catalog and requested by clients.

Changing a public URL does not move generated files. It only changes catalog URLs and requires a matching gateway route.

## Public media URL prefix

By default, generated catalog entries use `/media/generated`:

```json
{
  "hlsUrl": "/media/generated/demo/hls/master.m3u8",
  "dashUrl": "/media/generated/demo/dash/manifest.mpd"
}
```

The default works without any project-specific Nginx configuration.

To expose generated media under `/videos`, add this value to the local `.env` file:

```dotenv
MEDIA_URL_PREFIX=/videos
```

Then create `gateway/project-routes/project.conf`:

```nginx
location /videos/ {
  # The trailing slashes replace /videos/ with /media/generated/ upstream.
  proxy_pass http://origin_upstream/media/generated/;
  proxy_http_version 1.1;
  proxy_set_header Connection "";
  proxy_buffering off;
  proxy_force_ranges on;
}
```

Rebuild the catalog and reload the gateway:

```bash
make catalog
docker compose exec gateway nginx -t
docker compose exec gateway nginx -s reload
make verify-media
```

The generated `media/catalog/v1/feed.json` and per-asset catalog files will now contain URLs such as:

```text
/videos/demo/progressive/video.mp4
/videos/demo/hls/master.m3u8
/videos/demo/dash/manifest.mpd
/videos/demo/storyboard/storyboard.vtt
```

Nested prefixes work the same way. For example:

```dotenv
MEDIA_URL_PREFIX=/mobile/v2/videos
```

```nginx
location /mobile/v2/videos/ {
  proxy_pass http://origin_upstream/media/generated/;
  proxy_http_version 1.1;
  proxy_set_header Connection "";
  proxy_buffering off;
  proxy_force_ranges on;
}
```

`MEDIA_URL_PREFIX` must be a root-relative path beginning with one `/`. Trailing and repeated slashes are normalized. Absolute URLs, query strings, fragments, whitespace, backslashes, `.` and `..` path segments are rejected.

The variable changes direct media URLs in these catalog fields:

- `progressiveUrl`, `hlsUrl`, and `dashUrl`;
- every `playback[].url`;
- every `renditions[].hlsUrl`;
- every `subtitles[].url`;
- `storyboard.url`.

It does not change `/api`, `/img`, `/cache`, `/no-range`, `/wrong-content-type`, or `/mock` routes. Those are built-in Media Lab API, image-transformation, and diagnostic endpoints.

To return to the default setup, remove `MEDIA_URL_PREFIX` from `.env`, remove project-specific `.conf` files, rebuild the catalog, and reload the gateway. The tracked `gateway/project-routes/` directory may remain empty.

## Project-specific gateway routes

Files matching `gateway/project-routes/*.conf` are loaded inside the gateway `server` block. They are optional: a fresh checkout contains an empty tracked directory and starts with only the built-in routes from [`gateway/nginx.conf`](../gateway/nginx.conf).

Route files should contain `location` blocks, not complete `http` or `server` blocks. Always validate changes before reloading:

```bash
docker compose exec gateway nginx -t
docker compose exec gateway nginx -s reload
```

Do not redefine an existing location such as `/media/`; Nginx rejects duplicate locations.

## Host media directories

The default bind mount is `./media:/media`. Consequently:

- `media/inbox` is available as `/media/inbox`;
- `media/generated` is available as `/media/generated`;
- `media/catalog` is available as `/media/catalog`.

To keep generated data in another host directory, add a Compose override instead of editing the base [`compose.yaml`](../compose.yaml). For example, `compose.local.yaml`:

```yaml
services:
  origin:
    volumes:
      - /absolute/path/to/shared-media:/srv/media:ro

  imgproxy:
    volumes:
      - /absolute/path/to/shared-media/images:/srv/images
      - /absolute/path/to/shared-media/generated:/srv/images/generated:ro

  media-ingest:
    volumes:
      - /absolute/path/to/shared-media:/media

  media-catalog:
    volumes:
      - /absolute/path/to/shared-media:/media
```

Use the override for every service shown above so ingest, catalog generation, origin, and imgproxy all see the same files:

```bash
docker compose -f compose.yaml -f compose.local.yaml --profile tools run --rm media-ingest
docker compose -f compose.yaml -f compose.local.yaml --profile tools run --rm media-catalog
docker compose -f compose.yaml -f compose.local.yaml up -d
```

Keep the container-side `/media` layout unless the corresponding service environment and all dependent mounts are changed together.

## Custom encoding ladder

The ingest container reads `/config/encoding-ladder.tsv`. To use another file, override both its environment value and mount:

```yaml
services:
  media-ingest:
    environment:
      MEDIA_LADDER_FILE: /config/project-ladder.tsv
    volumes:
      - ./config/project-ladder.tsv:/config/project-ladder.tsv:ro
```

Run `make rebuild` after changing the ladder so existing generated assets are re-encoded.

## Custom WireMock mappings

Project-specific mocked APIs can be added under [`wiremock/mappings/`](../wiremock/mappings), with response bodies under `wiremock/__files/`.

Example mapping:

```json
{
  "request": {
    "method": "GET",
    "url": "/api/v2/video/details"
  },
  "response": {
    "status": 200,
    "headers": {
      "Content-Type": "application/json"
    },
    "bodyFileName": "custom-video-details.json"
  }
}
```

Restart WireMock after adding or changing mappings:

```bash
docker compose restart wiremock
```

## Configurable Image Placeholders

During the ingestion process, the catalog builder generates image placeholder values inside the feed. This can be configured in `.env` using the `PLACEHOLDER_ALGORITHM` variable:

```dotenv
PLACEHOLDER_ALGORITHM=blurhash
```

The supported algorithms are:

- `blurhash` (default): Encodes a standard BlurHash string.
- `thumbhash`: Encodes a ThumbHash base64 string, representing the image with transparency and aspect ratio details.
- `lqip`: Low-Quality Image Placeholder. Generates a base64-encoded `16x16` WebP data URL suitable for zero-dependency native loading in Web and Coil KMP.
- `average_color`: Calculates the average sRGB color of the poster and outputs a HEX string.
- `none`: Disables the placeholder generation completely.

The computed values are populated into the `"placeholder"` object in `feed.json` and individual legacy keys (e.g., `"blurhash"`, `"thumbhash"`, `"lqip"`, `"averageColor"`) are also appended for compatibility.

