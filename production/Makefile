.PHONY: up down restart logs ps clean shell-app pull workspace

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

define COMPOSE_CMD
	if [ -f "docker-compose.override.yaml" ]; then \
		CMD="docker compose -f compose.base.yaml -f docker-compose.override.yaml"; \
	else \
		CMD="docker compose -f compose.base.yaml"; \
	fi
endef

up:
	$(require-project)
	@echo "Running service for the $(PROJECT) project..."
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD up -d

down:
	$(require-project)
	@echo "Stopping service for the $(PROJECT) project..."
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD down

restart:
	$(require-project)
	@echo "Restarting service for the $(PROJECT) project..."
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD restart

pull:
	$(require-project)
	@echo "Pulling latest image for the $(PROJECT) project..."
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD pull
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD up -d

logs:
	$(require-project)
	@echo "Showing logs for the $(PROJECT) project..."
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD logs -f

ps:
	$(require-project)
	@echo "Showing container status for the $(PROJECT) project..."
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD ps

clean:
	$(require-project)
	@echo "Warning: Stopping services and removing volumes for the $(PROJECT) project..."
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD down -v

shell-app:
	$(require-project)
	$(require-app)
	@echo "Entering $(APP) container..."
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD exec $(APP) bash

workspace:
	$(require-project)
	@echo "Entering PHP-CLI Workspace for $(PROJECT)..."
	@cd $(PROJECT) && $(COMPOSE_CMD) && $$CMD --profile workspace run --rm php-cli bash