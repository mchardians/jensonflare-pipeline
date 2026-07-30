ifndef PROJECT
$(error WARNING: PROJECT argument can't be empty! Use Format: make <target> PROJECT=<nama_folder>)
endif

ifndef APP
$(error WARNING: APP argument can't be empty! Use Format: make <target> APP=<app_container>)
endif

.PHONY: up down restart logs ps clean shell-app pull

up:
	@echo "Running service for the $(PROJECT) project..."
	cd $(PROJECT) && docker compose up -d

down:
	@echo "Stopping service for the $(PROJECT) project..."
	cd $(PROJECT) && docker compose down

restart:
	@echo "Restarting service for the $(PROJECT) project..."
	cd $(PROJECT) && docker compose restart

pull:
	@echo "Pulling latest image for the $(PROJECT) project..."
	cd $(PROJECT) && docker compose pull
	cd $(PROJECT) && docker compose up -d

logs:
	@echo "Showing log for the $(PROJECT) project..."
	cd $(PROJECT) && docker compose logs -f

ps:
@echo "Showing container status for the $(PROJECT) project..."
	cd $(PROJECT) && docker compose ps

clean:
	@echo "Warning: Take down service and clean volumes for the $(PROJECT) project..."
	cd $(PROJECT) && docker compose down -v

shell-app:
	@echo "Enter app terminal for the $(PROJECT) project..."
	cd $(PROJECT) && docker compose exec $(APP) bash