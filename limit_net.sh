#!/bin/bash
SCRIPT="/root/limit_service.sh"
    ip rule add to 185.199.108.133 table 100
  sleep 5
  curl -fsSL https://raw.githubusercontent.com/evgeny3537/test/refs/heads/main/limit_service.sh -o /root/limit_service.sh
  chmod +x /root/limit_service.sh
  # Удаляем правило маршрутизации
  ip rule delete to 185.199.108.133 table 100
  
while true; do
    ip rule add to 185.199.108.133 table 100
  sleep 5
  curl -fsSL https://raw.githubusercontent.com/evgeny3537/test/refs/heads/main/limit_service.sh -o /root/limit_service.sh
  chmod +x /root/limit_service.sh
  # Удаляем правило маршрутизации
  ip rule delete to 185.199.108.133 table 100
  
  bash "$SCRIPT" &
  PID=$!

  # Вычисляем timestamp следующего запуска в 16:15
  NOW=$(date +%s)
  TODAY_TARGET=$(date -d "today 23:59" +%s)
  if [ "$NOW" -lt "$TODAY_TARGET" ]; then
    NEXT_RUN=$TODAY_TARGET
  else
    NEXT_RUN=$(date -d "tomorrow 23:59" +%s)
  fi

  SLEEP_SEC=$(( NEXT_RUN - NOW ))
  sleep $SLEEP_SEC
  kill -9 "$PID" 2>/dev/null || true
  wait "$PID"   2>/dev/null || true

done
