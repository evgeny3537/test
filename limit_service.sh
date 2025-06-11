#!/bin/bash

# Параметры скорости и лимита
DEFAULT_RATE="1080kbit"
DEFAULT_MAX_RATE="900mbit"
OVERRIDE_IFACE="eno1"
OVERRIDE_IP="116.202.232.54"
OVERRIDE_MAX_RATE="200mbit"
LIMIT_BYTES=$((35 * 1024 * 1024 * 1024)) # 35 GB

# База данных использования трафика
DB_DIR="/var/lib/iface_limiter"
DB_FILE="$DB_DIR/iface_usage.db"
mkdir -p "$DB_DIR"

# Модули и интерфейсы
modprobe ifb
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vm[0-9]+_net0$')

# Ассоциативные массивы для статистики
declare -A usage prev_usage

# Обнуление при старте
echo "Сбрасываем статистику трафика"
: > "$DB_FILE"

# Загрузка статистики из файла
load_usage_db() {
    [[ -f "$DB_FILE" ]] || return
    while IFS='=' read -r iface bytes; do
        usage["$iface"]=$bytes
    done < "$DB_FILE"
}

# Сохранение статистики в файл
save_usage_db() {
    : > "$DB_FILE"
    for iface in "${!usage[@]}"; do
        echo "$iface=${usage[$iface]}" >> "$DB_FILE"
    done
}

# Получение отправленных байт для класса 1:20
get_sent_bytes() {
    local dev=$1 classid=$2
    tc -s class show dev "$dev" | awk -v cid="$classid" '
        $1=="class" && $3==cid { in=1 }
        in && $1=="Sent" {
            for(i=1;i<=NF;i++) if($i=="bytes") print $(i-1)
            exit
        }
        $1=="class" && $3!=cid { in=0 }
    '
}

# Проверка наличия класса 1:20 на устройстве
has_class20() {
    local dev=$1
    tc class show dev "$dev" | grep -q "class htb 1:20"
}

# Настройка tc и классов
setup_tc() {
    local dev=$1 ifb_dev=$2 max_rate

    # Определяем ceil-rate
    if [[ "$dev" == "$OVERRIDE_IFACE" ]] && ip addr show dev "$dev" | grep -qw "$OVERRIDE_IP"; then
        max_rate="$OVERRIDE_MAX_RATE"
    else
        max_rate="$DEFAULT_MAX_RATE"
    fi

    # Удаляем старые правила
    tc qdisc del dev "$dev" root     2>/dev/null
    tc qdisc del dev "$dev" ingress  2>/dev/null
    tc qdisc del dev "$ifb_dev" root  2>/dev/null

    # Настраиваем исходящий трафик
    tc qdisc add dev "$dev" root handle 1: htb default 20
    tc class add dev "$dev" parent 1: classid 1:10 htb rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE"
    tc class add dev "$dev" parent 1: classid 1:20 htb rate "$max_rate" ceil "$max_rate"
    tc qdisc add dev "$dev" parent 1:10 handle 10: fq_codel
    tc qdisc add dev "$dev" parent 1:20 handle 20: fq_codel

    # Настраиваем входящий трафик через IFB
    tc qdisc add dev "$dev" ingress handle ffff:
    tc filter add dev "$dev" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$ifb_dev"

    tc qdisc add dev "$ifb_dev" root handle 1: htb default 20
    tc class add dev "$ifb_dev" parent 1: classid 1:10 htb rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE"
    tc class add dev "$ifb_dev" parent 1: classid 1:20 htb rate "$max_rate" ceil "$max_rate"
    tc qdisc add dev "$ifb_dev" parent 1:10 handle 10: fq_codel
    tc qdisc add dev "$ifb_dev" parent 1:20 handle 20: fq_codel
}

# Применяем tc к всем интерфейсам один раз
load_usage_db
for iface in $INTERFACES; do
    ifb_dev="ifb_$iface"
    ip link add "$ifb_dev" type ifb 2>/dev/null || true
    ip link set dev "$ifb_dev" up
    setup_tc "$iface" "$ifb_dev"
done

# Основной мониторинг в цикле
while true; do
    for iface in $INTERFACES; do
        ifb_dev="ifb_$iface"

        # Пересоздаём правила, если их нет или отсутствует класс 1:20
        if ! tc qdisc show dev "$iface" | grep -q 'htb 1:' ||
           ! tc qdisc show dev "$ifb_dev" | grep -q 'htb 1:' ||
           ! has_class20 "$iface" ||
           ! has_class20 "$ifb_dev"; then
            echo "[INFO] Пересоздаём tc для $iface"
            setup_tc "$iface" "$ifb_dev"
        fi

        # Если IFB отсутствует — пропускаем сбор
        if ! ip link show dev "$ifb_dev" &>/dev/null; then
            echo "[WARN] $iface: $ifb_dev не найден — пропускаем"
            continue
        fi

        # Сбор статистики трафика
        out_bytes=$(get_sent_bytes "$iface" "1:20" || echo 0)
        in_bytes=$(get_sent_bytes "$ifb_dev" "1:20" || echo 0)
        current_total=$((out_bytes + in_bytes))

        prev=${prev_usage[$iface]:-0}
        used=${usage[$iface]:-0}

        # Аккумулируем
        if (( current_total < prev )); then
            usage[$iface]=$((used + current_total))
        else
            usage[$iface]=$((used + current_total - prev))
        fi
        prev_usage[$iface]=$current_total

        # Проверяем превышение лимита
        if (( usage[$iface] > LIMIT_BYTES )); then
            echo "[LIMIT] $iface превысил лимит, ставим throttle"
            tc filter add dev "$iface" parent 1: prio 1000 u32 match u32 0 0 flowid 1:10 2>/dev/null || true
            tc filter add dev "$ifb_dev" parent 1: prio 1000 u32 match u32 0 0 flowid 1:10 2>/dev/null || true
        fi
    done

    save_usage_db
    sleep 0.3
done
