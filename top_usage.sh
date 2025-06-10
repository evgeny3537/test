#!/bin/bash

DB_FILE="/tmp/iface_usage.db"

if [ ! -f "$DB_FILE" ]; then
    echo "Файл статистики не найден: $DB_FILE"
    exit 1
fi

echo "ТОП-10 интерфейсов по трафику:"
echo "=============================="
echo
awk -F= '{printf "%-15s %12.2f GB\n", $1, $2 / (1024 * 1024 * 1024)}' "$DB_FILE" \
    | sort -k2 -nr \
    | head -n 10

exit