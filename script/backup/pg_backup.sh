#!/bin/bash
#
# Физический бэкап PostgreSQL инстанса через pg_basebackup
#
# Использование: ./pg_backup.sh <instance>
# Примеры:
#   ./pg_backup.sh backend
#

set -euo pipefail

# Определение путей
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BACKUP_BASE_DIR="${PROJECT_ROOT}/backups/postgresql"
LOG_FILE="${PROJECT_ROOT}/logs/backup.log"
ENV_DIR="${PROJECT_ROOT}/env"
TG_ALERT_SCRIPT="${PROJECT_ROOT}/script/tg_bot_alert.py"

# Количество бэкапов для хранения
RETENTION_COUNT=3

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
        EMU_ALERT_TG_BOT_TOKEN="${EMU_ALERT_TG_BOT_TOKEN}" \
        EMU_ALERT_TG_CHAT_ID="${EMU_ALERT_TG_CHAT_ID}" \
        python3 "${TG_ALERT_SCRIPT}" "${message}" || log "WARN" "Failed to send Telegram notification"
    else
        log "WARN" "Telegram alert script not found or not executable: ${TG_ALERT_SCRIPT}"
    fi
}

# Проверка аргументов
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <instance>"
    echo "Available instances: backend"
    exit 1
fi

INSTANCE="$1"

# Преобразование имени инстанса в формат переменных окружения
# backend -> BACKEND
INSTANCE_UPPER=$(echo "${INSTANCE}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

# Загрузка переменных окружения из всех env файлов
for env_file in "${ENV_DIR}"/.env.{app,db,monitoring}; do
    if [[ -f "${env_file}" ]]; then
        set -a  # автоматически экспортировать все переменные
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

# Определение имени переменной контейнера
CONTAINER_VAR="EMU_${INSTANCE_UPPER}_POSTGRES_CONTAINER_NAME"
USER_VAR="EMU_${INSTANCE_UPPER}_POSTGRES_USER"
PASSWORD_VAR="EMU_${INSTANCE_UPPER}_POSTGRES_PASSWORD"

# Получение значений переменных
CONTAINER_NAME="${!CONTAINER_VAR:-}"
POSTGRES_USER="${!USER_VAR:-}"
POSTGRES_PASSWORD="${!PASSWORD_VAR:-}"

if [[ -z "${CONTAINER_NAME}" ]]; then
    log "ERROR" "Container name not found for instance: ${INSTANCE}"
    log "ERROR" "Expected variable: ${CONTAINER_VAR}"
    exit 1
fi

if [[ -z "${POSTGRES_USER}" ]]; then
    log "ERROR" "PostgreSQL user not found for instance: ${INSTANCE}"
    exit 1
fi

if [[ -z "${POSTGRES_PASSWORD}" ]]; then
    log "ERROR" "PostgreSQL password not found for instance: ${INSTANCE}"
    exit 1
fi

# Проверка, что контейнер запущен
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "ERROR" "Container is not running: ${CONTAINER_NAME}"
    send_telegram "❌ <b>ОШИБКА БЭКАПА</b>

📦 Инстанс: <code>${INSTANCE}</code>
🐳 Контейнер: <code>${CONTAINER_NAME}</code>
⚠️ Причина: Контейнер не запущен

⏱️ $(date '+%d.%m.%Y %H:%M:%S')"
    exit 1
fi

# Создание директории для бэкапов инстанса
INSTANCE_BACKUP_DIR="${BACKUP_BASE_DIR}/${INSTANCE}"
mkdir -p "${INSTANCE_BACKUP_DIR}"

# Генерация имени файла бэкапа с timestamp
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="${INSTANCE}_backup_${TIMESTAMP}"
BACKUP_DIR="/tmp/${BACKUP_NAME}"

log "INFO" "Starting backup for instance: ${INSTANCE}"
log "INFO" "Container: ${CONTAINER_NAME}"
log "INFO" "Backup directory: ${INSTANCE_BACKUP_DIR}"

# Создание временной директории внутри контейнера
docker exec "${CONTAINER_NAME}" mkdir -p "${BACKUP_DIR}" || {
    log "ERROR" "Failed to create backup directory in container"
    send_telegram "❌ <b>ОШИБКА БЭКАПА</b>

📦 Инстанс: <code>${INSTANCE}</code>
🐳 Контейнер: <code>${CONTAINER_NAME}</code>
⚠️ Причина: Не удалось создать директорию для бэкапа

⏱️ $(date '+%d.%m.%Y %H:%M:%S')"
    exit 1
}

# Запуск pg_basebackup внутри контейнера
log "INFO" "Running pg_basebackup..."

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" \
    pg_basebackup \
    -D "${BACKUP_DIR}" \
    -F tar \
    -z \
    -P \
    -U "${POSTGRES_USER}" \
    -w \
    --max-rate=50M \
    --checkpoint=fast || {
    log "ERROR" "pg_basebackup failed for instance: ${INSTANCE}"
    # Очистка
    docker exec "${CONTAINER_NAME}" rm -rf "${BACKUP_DIR}" 2>/dev/null || true
    send_telegram "❌ <b>ОШИБКА БЭКАПА</b>

📦 Инстанс: <code>${INSTANCE}</code>
🐳 Контейнер: <code>${CONTAINER_NAME}</code>
⚠️ Причина: Команда pg_basebackup завершилась с ошибкой

⏱️ $(date '+%d.%m.%Y %H:%M:%S')"
    exit 1
}

# Копирование бэкапа из контейнера на хост
log "INFO" "Copying backup from container to host..."

docker cp "${CONTAINER_NAME}:${BACKUP_DIR}/base.tar.gz" "${INSTANCE_BACKUP_DIR}/${BACKUP_NAME}.tar.gz" || {
    log "ERROR" "Failed to copy backup from container"
    docker exec "${CONTAINER_NAME}" rm -rf "${BACKUP_DIR}" 2>/dev/null || true
    send_telegram "❌ <b>ОШИБКА БЭКАПА</b>

📦 Инстанс: <code>${INSTANCE}</code>
🐳 Контейнер: <code>${CONTAINER_NAME}</code>
⚠️ Причина: Не удалось скопировать бэкап из контейнера

⏱️ $(date '+%d.%m.%Y %H:%M:%S')"
    exit 1
}

if ! tar -tzf "${INSTANCE_BACKUP_DIR}/${BACKUP_NAME}.tar.gz" >/dev/null 2>&1; then
    log "ERROR" "Backup archive is corrupted"
    exit 1
fi

# Копирование pg_wal если есть
if docker exec "${CONTAINER_NAME}" test -f "${BACKUP_DIR}/pg_wal.tar.gz"; then
    docker cp "${CONTAINER_NAME}:${BACKUP_DIR}/pg_wal.tar.gz" "${INSTANCE_BACKUP_DIR}/${BACKUP_NAME}_wal.tar.gz" || {
        log "WARN" "Failed to copy WAL backup, but base backup is complete"
    }
fi

# Очистка временной директории в контейнере
docker exec "${CONTAINER_NAME}" rm -rf "${BACKUP_DIR}" 2>/dev/null || {
    log "WARN" "Failed to cleanup temporary backup directory in container"
}

# Получение размера бэкапа
BACKUP_SIZE=$(du -h "${INSTANCE_BACKUP_DIR}/${BACKUP_NAME}.tar.gz" | cut -f1)

log "INFO" "Backup completed successfully"
log "INFO" "Backup file: ${BACKUP_NAME}.tar.gz"
log "INFO" "Backup size: ${BACKUP_SIZE}"

# Удаление старых бэкапов (оставляем только последние N полных пар)
log "INFO" "Cleaning up old backups (keeping last ${RETENTION_COUNT} complete pairs)..."

# Подсчет количества ПОЛНЫХ бэкапов (только пары с WAL файлами)
BACKUP_COUNT=0
for backup in $(ls -1 "${INSTANCE_BACKUP_DIR}"/${INSTANCE}_backup_*.tar.gz 2>/dev/null | grep -v "_wal\.tar\.gz$" || true); do
    wal_file="${backup%.tar.gz}_wal.tar.gz"
    if [[ -f "${wal_file}" ]]; then
        BACKUP_COUNT=$((BACKUP_COUNT + 1))
    fi
done

log "INFO" "Found ${BACKUP_COUNT} complete backup pairs"

if [[ ${BACKUP_COUNT} -gt ${RETENTION_COUNT} ]]; then
    # Удаляем старые ПОЛНЫЕ бэкапы (пары)
    BACKUPS_TO_DELETE=$((BACKUP_COUNT - RETENTION_COUNT))
    log "INFO" "Need to delete ${BACKUPS_TO_DELETE} old backup pair(s)"

    # Сортируем по времени (старые первые) и удаляем только полные пары
    deleted_count=0
    for backup in $(ls -1tr "${INSTANCE_BACKUP_DIR}"/${INSTANCE}_backup_*.tar.gz 2>/dev/null | grep -v "_wal\.tar\.gz$" || true); do
        wal_file="${backup%.tar.gz}_wal.tar.gz"
        if [[ -f "${wal_file}" ]] && [[ ${deleted_count} -lt ${BACKUPS_TO_DELETE} ]]; then
            log "INFO" "Deleting old backup pair: $(basename "${backup}") + WAL"
            rm -f "${backup}"
            rm -f "${wal_file}"
            deleted_count=$((deleted_count + 1))
        fi
    done
fi

# Отправка уведомления об успехе
send_telegram "✅ <b>БЭКАП УСПЕШНО ЗАВЕРШЁН</b>

📦 Инстанс: <code>${INSTANCE}</code>
🐳 Контейнер: <code>${CONTAINER_NAME}</code>
💾 Размер: <b>${BACKUP_SIZE}</b>
📁 Файл: <code>${BACKUP_NAME}.tar.gz</code>
⏱️ Время: $(date '+%d.%m.%Y %H:%M:%S')"

log "INFO" "Backup process completed for instance: ${INSTANCE}"

exit 0
