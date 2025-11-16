#!/bin/bash
#
# Список всех доступных бэкапов PostgreSQL
#
# Использование: ./pg_list_backups.sh [instance]
#
# Без аргументов - показывает все бэкапы
# С аргументом - показывает бэкапы только для указанного инстанса
#
# Примеры:
#   ./pg_list_backups.sh              # все бэкапы
#   ./pg_list_backups.sh backend      # только backend
#

set -euo pipefail

# Определение путей
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BACKUP_BASE_DIR="${PROJECT_ROOT}/backups/postgresql"

# Список всех инстансов
ALL_INSTANCES=("backend")

# Цвета для вывода
COLOR_RESET='\033[0m'
COLOR_HEADER='\033[1;36m'
COLOR_INSTANCE='\033[1;33m'
COLOR_FILE='\033[0;32m'
COLOR_SIZE='\033[0;35m'
COLOR_DATE='\033[0;34m'
COLOR_ERROR='\033[0;31m'

# Функция для форматирования размера файла
format_size() {
    local size_bytes=$1
    if [[ ${size_bytes} -ge 1073741824 ]]; then
        # >= 1 GB
        echo "$(awk "BEGIN {printf \"%.2f\", ${size_bytes}/1073741824}")G"
    elif [[ ${size_bytes} -ge 1048576 ]]; then
        # >= 1 MB
        echo "$(awk "BEGIN {printf \"%.2f\", ${size_bytes}/1048576}")M"
    elif [[ ${size_bytes} -ge 1024 ]]; then
        # >= 1 KB
        echo "$(awk "BEGIN {printf \"%.2f\", ${size_bytes}/1024}")K"
    else
        echo "${size_bytes}B"
    fi
}

# Функция для отображения бэкапов инстанса
show_instance_backups() {
    local instance="$1"
    local instance_dir="${BACKUP_BASE_DIR}/${instance}"

    # Проверка наличия директории
    if [[ ! -d "${instance_dir}" ]]; then
        echo -e "${COLOR_ERROR}  Directory not found: ${instance_dir}${COLOR_RESET}"
        return
    fi

    # Поиск бэкапов
    local backups=($(ls -1t "${instance_dir}"/${instance}_backup_*.tar.gz 2>/dev/null || true))

    if [[ ${#backups[@]} -eq 0 ]]; then
        echo -e "${COLOR_ERROR}  No backups found${COLOR_RESET}"
        return
    fi

    # Подсчет общего размера
    local total_size=0

    # Вывод информации о каждом бэкапе
    for backup_file in "${backups[@]}"; do
        local filename=$(basename "${backup_file}")
        local size_bytes=$(stat -c%s "${backup_file}")
        local size_human=$(format_size ${size_bytes})
        local mod_time=$(stat -c%y "${backup_file}" | cut -d'.' -f1)

        # Проверка наличия WAL файла
        local wal_marker=""
        local wal_file="${backup_file%.tar.gz}_wal.tar.gz"
        if [[ -f "${wal_file}" ]]; then
            wal_marker=" [+WAL]"
            local wal_size=$(stat -c%s "${wal_file}")
            size_bytes=$((size_bytes + wal_size))
            size_human=$(format_size ${size_bytes})
        fi

        total_size=$((total_size + size_bytes))

        echo -e "  ${COLOR_FILE}${filename}${wal_marker}${COLOR_RESET}"
        echo -e "    Size: ${COLOR_SIZE}${size_human}${COLOR_RESET}  |  Date: ${COLOR_DATE}${mod_time}${COLOR_RESET}"
        echo -e "    Path: ${backup_file}"
        echo ""
    done

    # Итоговая информация
    local total_human=$(format_size ${total_size})
    echo -e "  ${COLOR_HEADER}Total: ${#backups[@]} backup(s), ${total_human}${COLOR_RESET}"
}

# Основная логика
echo ""
echo -e "${COLOR_HEADER}=========================================${COLOR_RESET}"
echo -e "${COLOR_HEADER}PostgreSQL Backups${COLOR_RESET}"
echo -e "${COLOR_HEADER}=========================================${COLOR_RESET}"
echo ""

# Проверка наличия директории бэкапов
if [[ ! -d "${BACKUP_BASE_DIR}" ]]; then
    echo -e "${COLOR_ERROR}Backup directory not found: ${BACKUP_BASE_DIR}${COLOR_RESET}"
    echo ""
    exit 1
fi

# Определение инстансов для отображения
if [[ $# -eq 1 ]]; then
    # Показать только указанный инстанс
    INSTANCE="$1"

    # Проверка валидности инстанса
    if [[ ! " ${ALL_INSTANCES[@]} " =~ " ${INSTANCE} " ]]; then
        echo -e "${COLOR_ERROR}Unknown instance: ${INSTANCE}${COLOR_RESET}"
        echo "Available instances: ${ALL_INSTANCES[*]}"
        echo ""
        exit 1
    fi

    INSTANCES=("${INSTANCE}")
else
    # Показать все инстансы
    INSTANCES=("${ALL_INSTANCES[@]}")
fi

# Отображение бэкапов для каждого инстанса
TOTAL_BACKUPS=0
TOTAL_SIZE=0

for instance in "${INSTANCES[@]}"; do
    echo -e "${COLOR_INSTANCE}Instance: ${instance}${COLOR_RESET}"
    echo "---"

    instance_dir="${BACKUP_BASE_DIR}/${instance}"

    if [[ -d "${instance_dir}" ]]; then
        show_instance_backups "${instance}"

        # Подсчет статистики
        count=$(ls -1 "${instance_dir}"/${instance}_backup_*.tar.gz 2>/dev/null | wc -l)
        TOTAL_BACKUPS=$((TOTAL_BACKUPS + count))

        for backup_file in "${instance_dir}"/${instance}_backup_*.tar.gz; do
            if [[ -f "${backup_file}" ]]; then
                size=$(stat -c%s "${backup_file}")
                TOTAL_SIZE=$((TOTAL_SIZE + size))

                # Добавляем размер WAL если есть
                wal_file="${backup_file%.tar.gz}_wal.tar.gz"
                if [[ -f "${wal_file}" ]]; then
                    wal_size=$(stat -c%s "${wal_file}")
                    TOTAL_SIZE=$((TOTAL_SIZE + wal_size))
                fi
            fi
        done
    else
        echo -e "${COLOR_ERROR}  Directory not found${COLOR_RESET}"
        echo ""
    fi

    echo ""
done

# Итоговая статистика
if [[ ${TOTAL_BACKUPS} -gt 0 ]]; then
    TOTAL_SIZE_HUMAN=$(format_size ${TOTAL_SIZE})

    echo -e "${COLOR_HEADER}=========================================${COLOR_RESET}"
    echo -e "${COLOR_HEADER}Summary${COLOR_RESET}"
    echo -e "${COLOR_HEADER}=========================================${COLOR_RESET}"
    echo -e "Total backups: ${COLOR_FILE}${TOTAL_BACKUPS}${COLOR_RESET}"
    echo -e "Total size: ${COLOR_SIZE}${TOTAL_SIZE_HUMAN}${COLOR_RESET}"
    echo ""
fi

exit 0
