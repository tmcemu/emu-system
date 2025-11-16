#!/bin/bash
#
# Установка cron задачи для автоматического бэкапа PostgreSQL
#
# Использование: ./install_cron.sh
#
# По умолчанию: ежедневный бэкап в 03:00
# Для изменения времени отредактируйте переменную CRON_SCHEDULE
#

set -euo pipefail

# Определение путей
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BACKUP_ALL_SCRIPT="${SCRIPT_DIR}/pg_backup_all.sh"

# Расписание cron (по умолчанию: ежедневно в 03:00)
# Формат: минута час день месяц день_недели
CRON_SCHEDULE="0 3 * * *"

# Имя для идентификации задачи в crontab
CRON_MARKER="# loom-postgresql-backup"

# Цвета для вывода
COLOR_RESET='\033[0m'
COLOR_INFO='\033[0;36m'
COLOR_SUCCESS='\033[0;32m'
COLOR_WARNING='\033[0;33m'
COLOR_ERROR='\033[0;31m'

# Функция логирования
log_info() {
    echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $*"
}

log_warning() {
    echo -e "${COLOR_WARNING}[WARNING]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*"
}

# Проверка наличия скрипта бэкапа
if [[ ! -x "${BACKUP_ALL_SCRIPT}" ]]; then
    log_error "Backup script not found or not executable: ${BACKUP_ALL_SCRIPT}"
    exit 1
fi

echo ""
log_info "=========================================="
log_info "PostgreSQL Backup Cron Installation"
log_info "=========================================="
echo ""

# Проверка, установлена ли уже задача
if crontab -l 2>/dev/null | grep -q "${CRON_MARKER}"; then
    log_warning "Cron job already exists!"
    echo ""
    log_info "Current cron job:"
    crontab -l 2>/dev/null | grep -A1 "${CRON_MARKER}"
    echo ""

    read -p "Do you want to reinstall it? (yes/no): " REINSTALL
    if [[ "${REINSTALL}" != "yes" ]]; then
        log_info "Installation cancelled"
        exit 0
    fi

    # Удаление существующей задачи
    log_info "Removing existing cron job..."
    crontab -l 2>/dev/null | grep -v "${CRON_MARKER}" | grep -v "pg_backup_all.sh" | crontab -
fi

# Формирование команды для cron
CRON_COMMAND="${BACKUP_ALL_SCRIPT} >> ${PROJECT_ROOT}/logs/backup.log 2>&1"

# Создание новой задачи
log_info "Installing new cron job..."
log_info "Schedule: ${CRON_SCHEDULE} (Daily at 03:00 AM)"
log_info "Command: ${CRON_COMMAND}"
echo ""

# Добавление задачи в crontab
(
    crontab -l 2>/dev/null || true
    echo "${CRON_MARKER}"
    echo "${CRON_SCHEDULE} ${CRON_COMMAND}"
) | crontab -

# Проверка установки
if crontab -l 2>/dev/null | grep -q "${CRON_MARKER}"; then
    log_success "Cron job installed successfully!"
    echo ""
    log_info "Current crontab:"
    crontab -l 2>/dev/null | grep -A1 "${CRON_MARKER}"
    echo ""
    log_info "=========================================="
    log_info "Backup will run automatically at 03:00 AM"
    log_info "Logs: ${PROJECT_ROOT}/logs/backup.log"
    log_info "=========================================="
    echo ""
else
    log_error "Failed to install cron job"
    exit 1
fi

# Проверка статуса cron сервиса
log_info "Checking cron service status..."

if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
    log_success "Cron service is running"
else
    log_warning "Cron service may not be running!"
    log_warning "Please check: systemctl status cron"
fi

echo ""
log_info "=========================================="
log_info "Installation complete!"
log_info "=========================================="
echo ""
log_info "Useful commands:"
echo "  - View crontab:        crontab -l"
echo "  - Remove cron job:     crontab -e  (then delete the lines with '${CRON_MARKER}')"
echo "  - Manual backup:       ${BACKUP_ALL_SCRIPT}"
echo "  - View logs:           tail -f ${PROJECT_ROOT}/logs/backup.log"
echo "  - List backups:        ${SCRIPT_DIR}/pg_list_backups.sh"
echo ""

exit 0
