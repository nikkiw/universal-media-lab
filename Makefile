SHELL := /bin/sh

HOST_IDS = HOST_UID=$$(id -u) HOST_GID=$$(id -g)

.PHONY: up up-observability down reset logs ps urls smoke \
	interactive ingest ingest-one rebuild catalog verify-media bootstrap \
	test-catalog ci-fixture test-runtime \
	network-clean network-lte network-3g network-flaky

up:
	docker compose up -d

up-observability:
	docker compose --profile observability up -d

down:
	docker compose down

reset:
	docker compose down -v --remove-orphans

logs:
	docker compose logs -f --tail=200

ps:
	docker compose ps

urls:
	./scripts/urls.sh

smoke:
	./scripts/smoke-test.sh

interactive:
	@$(HOST_IDS) docker compose --profile tools run --rm --entrypoint /bin/sh media-ingest

ingest:
	@$(HOST_IDS) docker compose --profile tools run --rm media-ingest
	@$(HOST_IDS) docker compose --profile tools run --rm media-catalog

ingest-one:
	@test -n "$(ID)" || { echo "Usage: make ingest-one ID=<file-name-or-asset-id>"; exit 2; }
	@MEDIA_ONLY="$(ID)" $(HOST_IDS) docker compose --profile tools run --rm media-ingest
	@$(HOST_IDS) docker compose --profile tools run --rm media-catalog

rebuild:
	@MEDIA_ONLY="$(ID)" MEDIA_FORCE=1 $(HOST_IDS) docker compose --profile tools run --rm media-ingest
	@$(HOST_IDS) docker compose --profile tools run --rm media-catalog

catalog:
	@$(HOST_IDS) docker compose --profile tools run --rm media-catalog

verify-media:
	./scripts/verify-media.sh

test-catalog:
	python3 -m unittest discover -s tests -p 'test_*.py'

ci-fixture:
	./scripts/ci-fixture.sh

test-runtime:
	./scripts/e2e-test.sh

bootstrap:
	$(MAKE) ingest
	$(MAKE) up
	$(MAKE) smoke
	$(MAKE) verify-media

network-clean:
	./scripts/network-profile.sh clean

network-lte:
	./scripts/network-profile.sh lte

network-3g:
	./scripts/network-profile.sh 3g

network-flaky:
	./scripts/network-profile.sh flaky
