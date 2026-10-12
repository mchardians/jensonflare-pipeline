.PHONY: up down restart logs ps clean shell-sonar shell-db pull

up:
	docker compose up -d

down:
	docker compose down

pull:
	docker compose pull
	docker compose up -d

restart:
	docker compose restart

ps:
	docker compose ps

logs:
	docker compose logs -f

clean:
	docker compose down -v

shell-sonar:
	docker exec -it observer_sonarqube bash

shell-db:
	docker exec -it observer_postgresql bash