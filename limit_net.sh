#!/usr/bin/env bash

### Параметры
SCRIPT_URL="https://raw.githubusercontent.com/evgeny3537/test/refs/heads/main/limit_service.sh"
SCRIPT_PATH="/root/limit_service.sh"
TARGET_IP="185.199.108.133"
TABLE_ID=100
LOG_FILE="/root/limit_net.log"
RUN_HOUR="05:00"
    pkill -f "$SCRIPT_PATH"
### Функция логирования
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') — $*" >> "$LOG_FILE"
}

### Инициализация лога
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  log "=== Начало лога limit_net.sh ==="
fi
log "Запуск limit_net.sh (PID $$)"

### Основной цикл
while true; do
  # 1) Временное правило для curl
  ip rule add to "$TARGET_IP" table "$TABLE_ID" 2>/dev/null || true

  # 2) Обновляем limit_service.sh
  if ! curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"; then
    log "Ошибка curl при загрузке скрипта"
    sleep 60
    continue
  fi
  chmod +x "$SCRIPT_PATH"

  # 3) Убираем временное правило
  ip rule delete to "$TARGET_IP" table "$TABLE_ID" 2>/dev/null || true

  # 4) Запускаем дочерний скрипт в фоне (отсоединённо от терминала)
  setsid bash "$SCRIPT_PATH" >/dev/null 2>&1 &
  LOCAL_CHILD_PIDS=($(pgrep -f "$SCRIPT_PATH"))
  COUNT=${#LOCAL_CHILD_PIDS[@]}
  log "Запущено $COUNT процессов limit_service.sh (PIDs: ${LOCAL_CHILD_PIDS[*]})"

  # 5) Считаем время до следующего запуска в $RUN_HOUR
  NOW=$(date +%s)
  TODAY_TARGET=$(date -d "today $RUN_HOUR" +%s)
  if (( NOW < TODAY_TARGET )); then
    NEXT_RUN=$TODAY_TARGET
  else
    NEXT_RUN=$(date -d "tomorrow $RUN_HOUR" +%s)
  fi
  SLEEP_SEC=$(( NEXT_RUN - NOW ))
  (( SLEEP_SEC < 0 )) && SLEEP_SEC=0

  # 6) Засыпаем
  sleep "$SLEEP_SEC"

  # 7) Останавливаем все запущенные процессов limit_service.sh
  if pgrep -f "$SCRIPT_PATH" >/dev/null; then
    pkill -f "$SCRIPT_PATH"
    log "Остановлены $COUNT процессов limit_service.sh"
  else
    log "limit_service.sh не найден для остановки"
  fi
exit
done
exit
### Запуск
# Чтобы скрипт работал непрерывно, запустите его вне терминала:
# setsid bash /root/limit_net.sh & disown
