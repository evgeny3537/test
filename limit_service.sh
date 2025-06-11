#!/bin/bash

DEFAULT_RATE="1080kbit"
DEFAULT_MAX_RATE="900mbit"
OVERRIDE_IFACE="eno1"
OVERRIDE_IP="116.202.232.54"
OVERRIDE_MAX_RATE="100mbit"
LIMIT_BYTES=$((35 * 1024 * 1024 * 1024)) # 35 GB

DB_DIR="/var/lib/iface_limiter"
DB_FILE="$DB_DIR/iface_usage.db"
mkdir -p "$DB_DIR"

# ОБНУЛЕНИЕ СТАТИСТИКИ ПРИ ПЕРЕЗАПУСКЕ
echo "Обнуляем статистику трафика"
: > "$DB_FILE"

INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vm[0-9]+_net0$')
declare -A usage prev_usage limited_ifaces

modprobe ifb

# Загрузка накопленных данных
t_load_usage_db() {
    while IFS='=' read -r iface bytes; do
        usage["$iface"]=$bytes
    done < "$DB_FILE"
}

# Сохранение данных в БД
t_save_usage_db() {
    : > "$DB_FILE"
    for iface in "${!usage[@]}"; do
        echo "$iface=${usage[$iface]}" >> "$DB_FILE"
    done
}

# Установка tc и классов
t_setup_tc() {
    local dev=$1 ifb=$2
    local max_rate
n    # Override for specific interface
    if [[ "$dev" == "$OVERRIDE_IFACE" ]] && ip addr show dev "$dev" | grep -qw "$OVERRIDE_IP"; then
        max_rate="$OVERRIDE_MAX_RATE"
    else
        max_rate="$DEFAULT_MAX_RATE"
    fi

    # Удаляем старые правила
    tc qdisc del dev "$dev" root 2>/dev/null
    tc qdisc del dev "$dev" ingress 2>/dev/null
    tc qdisc del dev "$ifb" root 2>/dev/null

    # Создаем root qdisc
    tc qdisc add dev "$dev" root handle 1: htb default 20
    tc class add dev "$dev" parent 1: classid 1:10 htb rate $DEFAULT_RATE ceil $DEFAULT_RATE
    tc class add dev "$dev" parent 1: classid 1:20 htb rate $max_rate ceil $max_rate
    tc qdisc add dev "$dev" parent 1:10 handle 10: fq_codel
    tc qdisc add dev "$dev" parent 1:20 handle 20: fq_codel

    # Ingress mirroring
    tc qdisc add dev "$dev" ingress handle ffff:
    tc filter add dev "$dev" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$ifb"

    # Setup ifb egress
    tc qdisc add dev "$ifb" root handle 1: htb default 20
    tc class add dev "$ifb" parent 1: classid 1:10 htb rate $DEFAULT_RATE ceil $DEFAULT_RATE
    tc class add dev "$ifb" parent 1: classid 1:20 htb rate $max_rate ceil $max_rate
    tc qdisc add dev "$ifb" parent 1:10 handle 10: fq_codel
    tc qdisc add dev "$ifb" parent 1:20 handle 20: fq_codel
}

# Проверка наличия класса 1:20
t_check_class20() {
    local dev=$1
    tc class show dev "$dev" | grep -q "class htb 1:20"
}

# Главный цикл
load_usage_db

# Первичная настройка интерфейсов
for iface in $INTERFACES; do
    IFB_IF="ifb_${iface}"
    ip link add "$IFB_IF" type ifb &>/dev/null || true
    ip link set dev "$IFB_IF" up
    t_setup_tc "$iface" "$IFB_IF"
done

while true; do
    for iface in $INTERFACES; do
        IFB_IF="ifb_${iface}"

        # Пересоздаем правила, если отсутствует qdisc или класс 1:20
        if ! tc qdisc show dev "$iface" | grep -q "htb 1:" || \
           ! tc qdisc show dev "$IFB_IF" | grep -q "htb 1:" || \
           ! t_check_class20 "$iface" || \
           ! t_check_class20 "$IFB_IF"; then
            echo "Пересоздаем tc для $iface"
            t_setup_tc "$iface" "$IFB_IF"
        fi

        # Если IFB отсутствует — пропускаем
        if ! ip link show dev "$IFB_IF" &>/dev/null; then
            echo "$iface: $IFB_IF отсутствует, пропускаем"
            continue
        fi

        # Сбор статистики трафика
        out_bytes=$(get_sent_bytes "$iface" "1:20")
        in_bytes=$(get_sent_bytes "$IFB_IF" "1:20")
        out_bytes=${out_bytes:-0}
        in_bytes=${in_bytes:-0}
        current_total=$((out_bytes + in_bytes))

        prev=${prev_usage[$iface]:-0}
        used_so_far=${usage[$iface]:-0}

        if [ "$current_total" -lt "$prev" ]; then
            usage[$iface]=$((used_so_far + current_total))
        else
            usage[$iface]=$((used_so_far + current_total - prev))
        fi

        prev_usage[$iface]=$current_total
        total_used=${usage[$iface]:-0}

        # Применяем ограничение после превышения
        if [ "$total_used" -gt "$LIMIT_BYTES" ]; then
            if ! tc filter show dev "$iface" parent 1: | grep -q "priority 1000 .*classid 1:10"; then
                echo "$iface превысил лимит — применяем ограничение"
                tc filter add dev "$iface" protocol ip parent 1: prio 1000 u32 match u32 0 0 flowid 1:10
            fi
            if ! tc filter show dev "$IFB_IF" parent 1: | grep -q "priority 1000 .*classid 1:10"; then
                tc filter add dev "$IFB_IF" protocol ip parent 1: prio 1000 u32 match u32 0 0 flowid 1:10
            fi
        fi

        sleep 0.1
    done

    save_usage_db
    sleep 0.3
done
