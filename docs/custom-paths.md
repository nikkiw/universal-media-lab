# Customizing Paths Guide

This guide explains how to customize the directory paths, volume mounts, URL routing paths, and configuration locations within the **Universal Media Lab** to match your project's specific backend structure.

---

## 1. Customizing Media Directories (Inbox, Generated, Catalog)

By default, the media ingest tool uses directories relative to the repository root:
* **Inbox**: `/media/inbox` (where you place raw source videos)
* **Generated Outputs**: `/media/generated` (where MP4, HLS, and DASH files are compiled)
* **Catalog API**: `/media/catalog` (where static JSON endpoints are compiled)

### Using Environment Variables
You can override the directories processed by the ingest scripts without modifying the container structure. Add or update these variables in your local `.env` file:

```bash
# Ingest script overrides
MEDIA_INPUT_ROOT=/media/my-custom-inbox
MEDIA_OUTPUT_ROOT=/media/my-custom-output
MEDIA_STORYBOARD_INTERVAL=10

# Catalog builder overrides
MEDIA_ROOT=/media
```

### Overriding Host Volumes in Docker Compose
If you want to read source videos from or write transcoded files to directories outside of the project root (e.g. a shared external hard drive or another local project directory), modify the volume mapping inside [compose.yaml](file:///Users/dev/Developer/@PortfolioProjects/media-lab/compose.yaml):

```yaml
  media-ingest:
    # ...
    volumes:
      - ./scripts/media-ingest.sh:/scripts/media-ingest.sh:ro
      - ./config/encoding-ladder.tsv:/config/encoding-ladder.tsv:ro
      - /absolute/path/to/my/external/videos:/media/inbox      # Custom host path
      - /absolute/path/to/my/client/project/assets:/media/generated # Custom output path
      - ./media:/media
```

> [!WARNING]
> Keep the container mount paths (the right side of the `:` colon) as `/media/inbox` and `/media/generated` unless you also update the corresponding environment variables (`MEDIA_INPUT_ROOT`/`MEDIA_OUTPUT_ROOT`) to match the new container directories.

---

## 2. Customizing the Encoding Ladder File Path

By default, the encoding profiles (resolutions, bitrates, buffer sizing) are read from [config/encoding-ladder.tsv](file:///Users/dev/Developer/@PortfolioProjects/media-lab/config/encoding-ladder.tsv).

To use a custom encoding ladder:
1. Create your custom TSV file (e.g., `config/my-ladder.tsv`).
2. Add the variable to `.env`:
   ```bash
   MEDIA_LADDER_FILE=/config/my-ladder.tsv
   ```
3. Mount your file into the `media-ingest` service inside [compose.yaml](file:///Users/dev/Developer/@PortfolioProjects/media-lab/compose.yaml):
   ```yaml
   volumes:
     - ./config/my-ladder.tsv:/config/my-ladder.tsv:ro
   ```

---

## 3. Customizing WireMock Mock Mappings

If you need to mock custom production API paths (e.g. `/api/v2/users/profile` or `/cdn/video/manifest`), you can define project-specific paths using WireMock mappings.

Place files into the following paths:
* **JSON Request/Response Definitions**: [wiremock/mappings/](file:///Users/dev/Developer/@PortfolioProjects/media-lab/wiremock/mappings)
* **Response Body Fixtures**: `wiremock/__files/`

### Example: Mocking a custom video JSON endpoint
Create [wiremock/mappings/custom-video.json](file:///Users/dev/Developer/@PortfolioProjects/media-lab/wiremock/mappings/custom-video.json):
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

Then place your JSON response body file into `wiremock/__files/custom-video-details.json`. Restart the WireMock container to load changes:
```bash
docker compose restart wiremock
```

---

## 4. Customizing Nginx URL Gateway Routing

The main gateway routes incoming HTTP requests to downstream services based on URL prefixes. You can customize these routing locations inside [gateway/nginx.conf](file:///Users/dev/Developer/@PortfolioProjects/media-lab/gateway/nginx.conf).

### Example: Routing a custom `/static/` prefix to the origin server
If your client application expects assets under a `/static/` path rather than `/media/`, open [gateway/nginx.conf](file:///Users/dev/Developer/@PortfolioProjects/media-lab/gateway/nginx.conf) and map the new location block:

```nginx
# Map /static/ to the media origin server
location /static/ {
  proxy_pass http://origin_upstream;
  proxy_http_version 1.1;
  proxy_set_header Connection "";
  proxy_buffering off;
}
```

Then edit [origin/nginx.conf](file:///Users/dev/Developer/@PortfolioProjects/media-lab/origin/nginx.conf) to handle the static prefix, or map an alias:

```nginx
location /static/ {
  alias /srv/media/; # Maps http://gateway/static/video.mp4 to /srv/media/video.mp4
  autoindex on;
}
```

Remember to reload Nginx configuration after any routing changes:
```bash
docker compose exec gateway nginx -s reload
docker compose exec origin nginx -s reload
```
