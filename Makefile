.PHONY: deploy build-all stop-all update-all rebuild-all
.PHONY: rebuild-app stop-app
.PHONY: rebuild-monitoring stop-monitoring
.PHONY: rebuild-db stop-db
.PHONY: set-env set-env-to-config-template

set-env:
	@export $(cat env/.env.app env/.env.db env/.env.monitoring | xargs)

set-env-to-config-template:
	@envsubst < ${EMU_LOKI_CONFIG_FILE}.template > ${EMU_LOKI_CONFIG_FILE}
	@envsubst < ${EMU_MONITORING_REDIS_CONFIG_FILE}.template > ${EMU_MONITORING_REDIS_CONFIG_FILE}
	@envsubst < ${EMU_TEMPO_CONFIG_FILE}.template > ${EMU_TEMPO_CONFIG_FILE}
	@envsubst < ${EMU_OTEL_COLLECTOR_CONFIG_FILE}.template > ${EMU_OTEL_COLLECTOR_CONFIG_FILE}

deploy:
	@apt update && apt upgrade -y
	@apt install python3-pip git make
	@pip install requests --break-system-packages
	@cd ..
	@git clone git@github.com:tmcemu/emu-frontend.git
	@git clone git@github.com:tmcemu/emu-backend.git
	@cd emu-system
	@./infrastructure/nginx/install.sh
	@./infrastructure/docker/install.sh
	@mkdir -p backups/postgresql/backend logs script/backup
	@mkdir -p volumes/{grafana,loki,tempo,redis,postgresql,victoria-metrics}
	@mkdir -p volumes/redis/monitoring
	@mkdir -p volumes/weed
	@mkdir -p volumes/postgresql/{backend,grafana}
	@chmod -R 777 volumes
	@docker build -f script/migration/Dockerfile -t migration-base:latest .

build-all: set-env-to-config-template
	@docker compose -f ./docker-compose/db.yaml up --build
	sleep 20
	@docker compose -f ./docker-compose/monitoring.yaml up --build
	sleep 20
	@docker compose -f ./docker-compose/app.yaml up --build


stop-all:
	@docker compose -f ./docker-compose/app.yaml down
	@docker compose -f ./docker-compose/monitoring.yaml down
	@docker compose -f ./docker-compose/db.yaml down

update-all:
	@git pull
	@cd ../emu-frontend/ && git fetch origin && git checkout main && git reset --hard origin/main && cd ../emu-system/
	@cd ../emu-backend/ && git fetch origin && git checkout main && git reset --hard origin/main && cd ../emu-system/

rebuild-all: update-all build-all

rebuild-app: update-all set-env-to-config-template
	@docker compose -f ./docker-compose/apps.yaml up -d --build

stop-app:
	@docker compose -f ./docker-compose/apps.yaml down

stop-monitoring:
	@docker compose -f ./docker-compose/monitoring.yaml down

stop-db:
	@docker compose -f ./docker-compose/db.yaml down

rebuild-monitoring: update-all set-env-to-config-template
	@docker compose -f ./docker-compose/monitoring.yaml down
	@docker compose -f ./docker-compose/monitoring.yaml up -d --build

rebuild-db: update-all set-env-to-config-template
	@docker compose -f ./docker-compose/db.yaml down
	@docker compose -f ./docker-compose/db.yaml up -d --build

backup:
	@echo "Starting backup for all PostgreSQL instances..."
	@./script/backup/pg_backup_all.sh

backup-backend:
	@echo "Starting backup for backend instance..."
	@./script/backup/pg_backup.sh backend

list-backups:
	@./script/backup/pg_list_backups.sh

restore:
	@if [ -z "$(INSTANCE)" ] || [ -z "$(BACKUP)" ]; then \
		echo "Error: INSTANCE and BACKUP parameters are required"; \
		echo "Usage: make restore INSTANCE=<instance> BACKUP=<path_to_backup>"; \
		echo "Example: make restore INSTANCE=backend BACKUP=backups/postgresql/backend/backend_backup_20250112_030000.tar.gz"; \
		exit 1; \
	fi
	@echo "Starting restore for instance: $(INSTANCE)"
	@echo "Backup file: $(BACKUP)"
	@./script/backup/pg_restore.sh $(INSTANCE) $(BACKUP)

install-backup-cron:
	@echo "Installing cron job for automatic backups..."
	@./script/backup/install_cron.sh