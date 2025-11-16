#!/bin/bash
#
# Восстановление PostgreSQL инстанса из физического бэкапа
#
# Использование: ./pg_restore.sh <instance> <backup_file>
# Примеры:
#   ./pg_restore.sh backend /path/to/backend_backup_20250112_030000.tar.gz
#   ./pg_restore.sh authorization backups/postgresql/authorization/authorization_backup_20250112_030000.tar.gz
#

set -euo pipefail

# Определение путей
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_FILE="${PROJECT_ROOT}/logs/backup.log"
ENV_DIR="${PROJECT_ROOT}/env"
TG_ALERT_SCRIPT="${PROJECT_ROOT}/script/tg_bot_alert.py"

# Функция логирования
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

# Функция отправки Telegram уведомления
send_telegram() {
    local message="$1"
    if [[ -x "${TG_ALERT_SCRIPT}" ]]; then
        # Явно передаем переменные окружения в Python процесс
        LOOM_ALERT_TG_BOT_TOKEN="${LOOM_ALERT_TG_BOT_TOKEN}" \
        LOOM_ALERT_TG_CHAT_ID="${LOOM_ALERT_TG_CHAT_ID}" \
        python3 "${TG_ALERT_SCRIPT}" "${message}" || log "WARN" "Failed to send Telegram notification"
    else
        log "WARN" "Telegram alert script not found or not executable: ${TG_ALERT_SCRIPT}"
    fi
}

# Функция очистки при ошибке
cleanup_on_error() {
    log "ERROR" "Restore failed, cleaning up..."

    # Попытка запустить контейнер обратно
    if [[ -n "${CONTAINER_NAME:-}" ]]; then
        log "INFO" "Attempting to restart container: ${CONTAINER_NAME}"
        docker start "${CONTAINER_NAME}" 2>/dev/null || log "ERROR" "Failed to restart container"
    fi
}

# Установка trap для обработки ошибок
trap cleanup_on_error ERR

# Проверка аргументов
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <instance> <backup_file>"
    echo ""
    echo "Arguments:"
    echo "  instance     - PostgreSQL instance name (backend)"
    echo "  backup_file  - Path to backup file (*.tar.gz)"
    echo ""
    echo "Example:"
    echo "  $0 backend backups/postgresql/backend/backend_backup_20250112_030000.tar.gz"
    exit 1
fi

INSTANCE="$1"
BACKUP_FILE="$2"

# Преобразование имени инстанса в формат переменных окружения
INSTANCE_UPPER=$(echo "${INSTANCE}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

# Проверка наличия файла бэкапа
if [[ ! -f "${BACKUP_FILE}" ]]; then
    log "ERROR" "Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

# Получение абсолютного пути к файлу бэкапа
BACKUP_FILE=$(realpath "${BACKUP_FILE}")

log "INFO" "=========================================="
log "INFO" "Starting restore for instance: ${INSTANCE}"
log "INFO" "Backup file: ${BACKUP_FILE}"
log "INFO" "=========================================="

# Загрузка переменных окружения из всех env файлов
for env_file in "${ENV_DIR}"/.env.{app,db,monitoring}; do
    if [[ -f "${env_file}" ]]; then
        set -a
        source "${env_file}"
        set +a
    else
        log "WARN" "Environment file not found: ${env_file}"
    fi
done

# Проверка наличия основного файла с БД
if [[ ! -f "${ENV_DIR}/.env.db" ]]; then
    log "ERROR" "Database environment file not found: ${ENV_DIR}/.env.db"
    exit 1
fi

# Определение переменных
CONTAINER_VAR="LOOM_${INSTANCE_UPPER}_POSTGRES_CONTAINER_NAME"
VOLUME_VAR="LOOM_${INSTANCE_UPPER}_POSTGRES_VOLUME_DIR"

CONTAINER_NAME="${!CONTAINER_VAR:-}"
VOLUME_DIR="${!VOLUME_VAR:-}"

if [[ -z "${CONTAINER_NAME}" ]]; then
    log "ERROR" "Container name not found for instance: ${INSTANCE}"
    exit 1
fi

if [[ -z "${VOLUME_DIR}" ]]; then
    log "ERROR" "Volume directory not found for instance: ${INSTANCE}"
    exit 1
fi

# Полный путь к volume на хосте
FULL_VOLUME_PATH="${PROJECT_ROOT}/${VOLUME_DIR}"

# Проверка наличия WAL бэкапа
WAL_BACKUP_FILE="${BACKUP_FILE%.tar.gz}_wal.tar.gz"
HAS_WAL_BACKUP=false
if [[ -f "${WAL_BACKUP_FILE}" ]]; then
    HAS_WAL_BACKUP=true
    log "INFO" "WAL backup found: ${WAL_BACKUP_FILE}"
fi

# Запрос подтверждения у пользователя
echo ""
echo "WARNING: This will DESTROY all data in the PostgreSQL instance: ${INSTANCE}"
echo "Container: ${CONTAINER_NAME}"
echo "Volume: ${FULL_VOLUME_PATH}"
echo ""
read -p "Are you sure you want to continue? (type 'yes' to confirm): " CONFIRMATION

if [[ "${CONFIRMATION}" != "yes" ]]; then
    log "INFO" "Restore cancelled by user"
    exit 0
fi

# Проверка, запущен ли контейнер
IS_RUNNING=false
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    IS_RUNNING=true
    log "INFO" "Container is running, will be stopped"
fi

# Остановка контейнера
if [[ "${IS_RUNNING}" == "true" ]]; then
    log "INFO" "Stopping container: ${CONTAINER_NAME}"
    docker stop "${CONTAINER_NAME}" || {
        log "ERROR" "Failed to stop container"
        exit 1
    }
    log "INFO" "Container stopped successfully"
fi

# Создание резервной копии текущих данных
BACKUP_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_DIR="${FULL_VOLUME_PATH}_backup_${BACKUP_TIMESTAMP}"

if [[ -d "${FULL_VOLUME_PATH}/pgdata" ]]; then
    log "INFO" "Creating backup of current data: ${BACKUP_DIR}"
    cp -r "${FULL_VOLUME_PATH}" "${BACKUP_DIR}" || {
        log "WARN" "Failed to create backup of current data"
    }
fi

# Очистка volume директории
log "INFO" "Cleaning volume directory: ${FULL_VOLUME_PATH}"
rm -rf "${FULL_VOLUME_PATH}"/*

# Создание директории для восстановления
mkdir -p "${FULL_VOLUME_PATH}/pgdata"

# Распаковка основного бэкапа
log "INFO" "Extracting base backup..."
tar -xzf "${BACKUP_FILE}" -C "${FULL_VOLUME_PATH}/pgdata" || {
    log "ERROR" "Failed to extract base backup"
    send_telegram "❌ <b>ОШИБКА ВОССТАНОВЛЕНИЯ</b>

🔄 Инстанс: <code>${INSTANCE}</code>
🐳 Контейнер: <code>${CONTAINER_NAME}</code>
⚠️ Причина: Не удалось распаковать базовый бэкап
📁 Файл: <code>$(basename "${BACKUP_FILE}")</code>

⏱️ $(date '+%d.%m.%Y %H:%M:%S')"
    exit 1
}

# Распаковка WAL бэкапа если есть
if [[ "${HAS_WAL_BACKUP}" == "true" ]]; then
    log "INFO" "Extracting WAL backup..."
    mkdir -p "${FULL_VOLUME_PATH}/pgdata/pg_wal"
    tar -xzf "${WAL_BACKUP_FILE}" -C "${FULL_VOLUME_PATH}/pgdata/pg_wal" || {
        log "WARN" "Failed to extract WAL backup, continuing without it"
    }
fi

# Создание recovery.signal для восстановления PostgreSQL
log "INFO" "Creating recovery.signal file..."
touch "${FULL_VOLUME_PATH}/pgdata/recovery.signal"

# Настройка restore_command для восстановления
log "INFO" "Configuring restore_command..."
cat >> "${FULL_VOLUME_PATH}/pgdata/postgresql.auto.conf" <<EOF
# Restore configuration (added by pg_restore.sh)
restore_command = '/bin/true'
EOF

# Установка правильных прав доступа
log "INFO" "Setting permissions..."
chown -R 999:999 "${FULL_VOLUME_PATH}" || {
    log "WARN" "Failed to set ownership, trying with sudo..."
    sudo chown -R 999:999 "${FULL_VOLUME_PATH}" || {
        log "ERROR" "Failed to set ownership even with sudo"
    }
}
chmod -R 700 "${FULL_VOLUME_PATH}/pgdata" || {
    log "WARN" "Failed to set permissions"
}

# Запуск контейнера
log "INFO" "Starting container: ${CONTAINER_NAME}"
docker start "${CONTAINER_NAME}" || {
    log "ERROR" "Failed to start container"
    send_telegram "❌ <b>ОШИБКА ВОССТАНОВЛЕНИЯ</b>

🔄 Инстанс: <code>${INSTANCE}</code>
🐳 Контейнер: <code>${CONTAINER_NAME}</code>
⚠️ Причина: Не удалось запустить контейнер после восстановления
📁 Файл: <code>$(basename "${BACKUP_FILE}")</code>

⏱️ $(date '+%d.%m.%Y %H:%M:%S')"
    exit 1
}

# Ожидание запуска PostgreSQL
log "INFO" "Waiting for PostgreSQL to start..."
MAX_WAIT=60
WAIT_COUNT=0

while [[ ${WAIT_COUNT} -lt ${MAX_WAIT} ]]; do
    if docker exec "${CONTAINER_NAME}" pg_isready -U postgres >/dev/null 2>&1; then
        log "INFO" "PostgreSQL is ready"
        break
    fi

    sleep 1
    ((++WAIT_COUNT))
done

if [[ ${WAIT_COUNT} -ge ${MAX_WAIT} ]]; then
    log "ERROR" "PostgreSQL did not start within ${MAX_WAIT} seconds"
    log "ERROR" "Check container logs: docker logs ${CONTAINER_NAME}"
    send_telegram "❌ <b>ОШИБКА ВОССТАНОВЛЕНИЯ</b>

🔄 Инстанс: <code>${INSTANCE}</code>
🐳 Контейнер: <code>${CONTAINER_NAME}</code>
⚠️ Причина: PostgreSQL не запустился в течение ${MAX_WAIT} секунд
📁 Файл: <code>$(basename "${BACKUP_FILE}")</code>

💡 Проверьте логи: <code>docker logs ${CONTAINER_NAME}</code>
⏱️ $(date '+%d.%m.%Y %H:%M:%S')"
    exit 1
fi

# Проверка состояния базы данных
log "INFO" "Verifying database..."
DB_COUNT=$(docker exec "${CONTAINER_NAME}" psql -U postgres -t -c "SELECT count(*) FROM pg_database;" 2>/dev/null | xargs || echo "0")

if [[ ${DB_COUNT} -gt 0 ]]; then
    log "INFO" "Database verification successful (${DB_COUNT} databases found)"
else
    log "WARN" "Could not verify database, but PostgreSQL is running"
fi

log "INFO" "=========================================="
log "INFO" "Restore completed successfully"
log "INFO" "Instance: ${INSTANCE}"
log "INFO" "Container: ${CONTAINER_NAME}"
log "INFO" "=========================================="

# Отправка уведомления об успехе
send_telegram "✅ <b>ВОССТАНОВЛЕНИЕ УСПЕШНО ЗАВЕРШЕНО</b>

🔄 Инстанс: <code>${INSTANCE}</code>
🐳 Контейнер: <code>${CONTAINER_NAME}</code>
📁 Файл бэкапа: <code>$(basename "${BACKUP_FILE}")</code>
💾 Резервная копия старых данных: <code>$(basename "${BACKUP_DIR}")</code>
⏱️ Время: $(date '+%d.%m.%Y %H:%M:%S')

✨ База данных готова к работе!"

exit 0
