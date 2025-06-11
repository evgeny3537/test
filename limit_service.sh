#!/bin/bash

DEFAULT_RATE="1080kbit"
GLOBAL_MAX_RATE="1024mbit"
SPECIAL_MAX_RATE="128mbit"
LIMIT_BYTES=$((35 * 1024 * 1024 * 1024)) # 35 ГБ

DB_DIR="/var/lib/iface_limiter"
DB_FILE="$DB_DIR/iface_usage.db"
mkdir -p "$DB_DIR"

# ОБНУЛЕНИЕ СТАТИСТИКИ ПРИ ПЕРЕЗАПУСКЕ
echo "Обнуляем статистику трафика"
: > "$DB_FILE"

INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vm[0-9]+_net0$|^eno1$')
declare -A usage
declare -A prev_usage

modprobe ifb

# Загрузка накопленных данных
load_usage_db() {
    while IFS='=' read -r iface bytes; do
        usage["$iface"]=$bytes
    done < "$DB_FILE"
}

# Сохранение данных в БД
save_usage_db() {
    : > "$DB_FILE"
    for iface in "${!usage[@]}"; do
        echo "$iface=${usage[$iface]}" >> "$DB_FILE"
    done
}

# Установка tc и классов
setup_tc() {
    local dev=$1
    local ifb=$2
    local max_rate=$3

    tc qdisc del dev "$dev" root 2>/dev/null
    tc qdisc del dev "$dev" ingress 2>/dev/null
    tc qdisc del dev "$ifb" root 2>/dev/null

    tc qdisc add dev "$dev" root handle 1: htb default 20
    tc class add dev "$dev" parent 1: classid 1:10 htb rate $DEFAULT_RATE ceil $DEFAULT_RATE
    tc class add dev "$dev" parent 1: classid 1:20 htb rate $max_rate ceil $max_rate
    tc qdisc add dev "$dev" parent 1:10 handle 10: fq_codel
    tc qdisc add dev "$dev" parent 1:20 handle 20: fq_codel

    tc qdisc add dev "$dev" ingress handle ffff:
    tc filter add dev "$dev" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$ifb"

    tc qdisc add dev "$ifb" root handle 1: htb default 20
    tc class add dev "$ifb" parent 1: classid 1:10 htb rate $DEFAULT_RATE ceil $DEFAULT_RATE
    tc class add dev "$ifb" parent 1: classid 1:20 htb rate $max_rate ceil $max_rate
    tc qdisc add dev "$ifb" parent 1:10 handle 10: fq_codel
    tc qdisc add dev "$ifb" parent 1:20 handle 20: fq_codel
}

# Есть ли фильтр prio 20?
filter20_exists() {
    local dev=$1
    tc class show dev "$dev" | grep -q "class htb 1:20"
}

# Добавление фильтра для classid 1:10
add_filter_to_10() {
    local dev=$1
    local prio=1000
    tc filter add dev "$dev" protocol ip parent 1: prio $prio u32 match u32 0 0 flowid 1:10
}

# Получение статистики
get_sent_bytes() {
    local dev=$1
    local classid=$2
    tc -s class show dev "$dev" | awk -v cid="$classid" '
        $1=="class" && $3==cid { in_class=1 }
        in_class && $1=="Sent" {
            for(i=1;i<=NF;i++) {
                if($i=="bytes") { print $(i-1); exit }
            }
        }
        $1=="class" && $3!=cid { in_class=0 }
    '
}

load_usage_db

# Начальная настройка каждого интерфейса
for iface in $INTERFACES; do
    IFB_IF="ifb_${iface}"
    [ ! -d "/sys/class/net/$IFB_IF" ] && ip link add "$IFB_IF" type ifb
    ip link set dev "$IFB_IF" up

    # Определяем max_rate: для eno1 с особым IP другой лимит
    if [[ "$iface" == "eno1" ]] && ip addr show dev eno1 | grep -q "116.202.232.54"; then
        MR=$SPECIAL_MAX_RATE
    else
        MR=$GLOBAL_MAX_RATE
    fi

    setup_tc "$iface" "$IFB_IF" "$MR"
done

while true; do
    for iface in $INTERFACES; do
        IFB_IF="ifb_${iface}"

        # Ежедневная проверка наличия prio 20
        if ! filter20_exists "$iface"; then
            echo "Фильтр 1:20 отсутствует на $iface — пересоздаем правила"
            if [[ "$iface" == "eno1" ]] && ip addr show dev eno1 | grep -q "116.202.232.54"; then
                MR=$SPECIAL_MAX_RATE
            else
                MR=$GLOBAL_MAX_RATE
            fi
            setup_tc "$iface" "$IFB_IF" "$MR"
            continue
        fi

        # Основной подсчет трафика
        out_bytes=$(get_sent_bytes "$iface" "1:20")
        in_bytes=$(get_sent_bytes "$IFB_IF" "1:20")
        out_bytes=${out_bytes:-0}
        in_bytes=${in_bytes:-0}
        current_total=$((out_bytes + in_bytes))

        prev=${prev_usage[$iface]:-0}
        used_so_far=${usage[$iface]:-0}

        if [ "$current_total" -lt "$prev" ]; then
            usage["$iface"]=$((used_so_far + current_total))
        else
            usage["$iface"]=$((used_so_far + current_total - prev))
        fi

        prev_usage["$iface"]=$current_total
        total_used=${usage[$iface]:-0}

        if [ "$total_used" -gt "$LIMIT_BYTES" ]; then
            echo "$iface превысил лимит — применяем ограничение"
            add_filter_to_10 "$iface"
            add_filter_to_10 "$IFB_IF"
        fi

        sleep 0.1
    done

    save_usage_db
    sleep 0.3
done
