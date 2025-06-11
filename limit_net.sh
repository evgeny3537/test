#!/bin/bash

# URL до скрипта
SCRIPT_URL="https://raw.githubusercontent.com/evgeny3537/test/refs/heads/main/limit_service.sh"
# Локальный путь
SCRIPT_PATH="/root/limit_service.sh"
# IP и таблица для временной маршрутизации
TARGET_IP="185.199.108.133"
TABLE_ID=100

while true; do
    # 1. Добавляем временное правило, чтобы curl шёл по нужному маршруту
    ip rule add to "$TARGET_IP" table "$TABLE_ID"

    # 2. Загружаем самую свежую версию скрипта
    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    # 3. Удаляем временное правило
    ip rule delete to "$TARGET_IP" table "$TABLE_ID"

    # 4. Запускаем скрипт в фоне и запоминаем PID
    bash "$SCRIPT_PATH" &
    CHILD_PID=$!

    # 5. Вычисляем время до следующего запуска в 23:59
    NOW=$(date +%s)
    TODAY_TARGET=$(date -d "today 23:59" +%s)
    if [ "$NOW" -lt "$TODAY_TARGET" ]; then
        NEXT_RUN=$TODAY_TARGET
    else
        NEXT_RUN=$(date -d "tomorrow 23:59" +%s)
    fi
    SLEEP_SEC=$(( NEXT_RUN - NOW ))

    # 6. Засыпаем до 23:59
    sleep "$SLEEP_SEC"

    # 7. По наступлению 23:59 останавливаем предыдущий экземпляр
    kill -9 "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID"        2>/dev/null || true

    # Цикл повторяется
done
