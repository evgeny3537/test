#!/bin/bash

SCRIPT="/root/limit_service.sh"

while true; do
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Запускаем $SCRIPT"
  bash "$SCRIPT" &
  PID=$!
  ip rule add to 185.199.108.133 table 100
  sleep 5
  curl -fsSL https://raw.githubusercontent.com/evgeny3537/test/refs/heads/main/limit_service.sh -o /root/limit_service.sh
  chmod +x /root/limit_service.sh
  # Удаляем правило маршрутизации
  ip rule delete to 185.199.108.133 table 100

  # Вычисляем timestamp следующего запуска в 16:15
  NOW=$(date +%s)
  TODAY_TARGET=$(date -d "today 23:59" +%s)
  if [ "$NOW" -lt "$TODAY_TARGET" ]; then
    NEXT_RUN=$TODAY_TARGET
  else
    NEXT_RUN=$(date -d "tomorrow 23:59" +%s)
  fi

  SLEEP_SEC=$(( NEXT_RUN - NOW ))
  echo "Ждём $SLEEP_SEC сек до следующего запуска"
  sleep $SLEEP_SEC

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Принудительно убиваем PID $PID"
  kill -9 "$PID" 2>/dev/null || true
  wait "$PID"   2>/dev/null || true

  echo "——————————"
done
