SHELL := /bin/sh

.PHONY: up up-observability down reset logs ps urls smoke network-clean network-lte network-3g network-flaky

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

network-clean:
	./scripts/network-profile.sh clean

network-lte:
	./scripts/network-profile.sh lte

network-3g:
	./scripts/network-profile.sh 3g

network-flaky:
	./scripts/network-profile.sh flaky
