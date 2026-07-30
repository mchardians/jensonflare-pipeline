.PHONY: up down restart logs ps clean shell-jenkins shell-sonar pull

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

shell-jenkins:
	docker exec -it jenkins bash

shell-sonar:
	docker exec -it sonarqube bash