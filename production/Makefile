.PHONY: up down restart logs ps clean shell-app pull

define require-project
	@if [ -z "$(PROJECT)" ]; then \
		echo "ERROR: PROJECT argument can't be empty!"; \
		echo "Usage: make <target> PROJECT=<project_folder>"; \
		exit 1; \
	fi
endef

define require-app
	@if [ -z "$(APP)" ]; then \
		echo "ERROR: APP argument can't be empty!"; \
		echo "Usage: make shell-app PROJECT=<project_folder> APP=<container_name>"; \
		exit 1; \
	fi
endef

up:
	$(require-project)
	@echo "Running service for the $(PROJECT) project..."
	@cd $(PROJECT) && docker compose up -d

down:
	$(require-project)
	@echo "Stopping service for the $(PROJECT) project..."
	@cd $(PROJECT) && docker compose down

restart:
	$(require-project)
	@echo "Restarting service for the $(PROJECT) project..."
	@cd $(PROJECT) && docker compose restart

pull:
	$(require-project)
	@echo "Pulling latest image for the $(PROJECT) project..."
	@cd $(PROJECT) && docker compose pull
	@cd $(PROJECT) && docker compose up -d

logs:
	$(require-project)
	@echo "Showing logs for the $(PROJECT) project..."
	@cd $(PROJECT) && docker compose logs -f

ps:
	$(require-project)
	@echo "Showing container status for the $(PROJECT) project..."
	@cd $(PROJECT) && docker compose ps

clean:
	$(require-project)
	@echo "Warning: Stopping services and removing volumes for the $(PROJECT) project..."
	@cd $(PROJECT) && docker compose down -v

shell-app:
	$(require-project)
	$(require-app)
	@echo "Entering $(APP) container..."
	@cd $(PROJECT) && docker compose exec $(APP) bash