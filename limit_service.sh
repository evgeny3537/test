#!/bin/bash

DEFAULT_RATE="2304kbit"
GLOBAL_MAX_RATE="750mbit"
SPECIAL_MAX_RATE="102mbit"
LIMIT_BYTES=$((50 * 1024 * 1024 * 1024)) # 

# Список идентификаторов VM для исключения (без префикса "vm" и постфикса "_net0").
# Добавьте сюда нужные цифры, например: EXCLUDE_IDS=(1143 1200)
EXCLUDE_IDS=(1143)
# Список физических интерфейсов для исключения целиком
EXCLUDE_IFACES=("eno1")

DB_DIR="/var/lib/iface_limiter"
DB_FILE="$DB_DIR/iface_usage.db"
mkdir -p "$DB_DIR"

# ОБНУЛЕНИЕ СТАТИСТИКИ ПРИ ПЕРЕЗАПУСКЕ
echo "Обнуляем статистику трафика"
: > "$DB_FILE"

# Список отслеживаемых интерфейсов (только vmXXX_net0)
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vm[0-9]+_net0$')
declare -A usage
declare -A prev_usage

modprobe ifb

# Функция проверки, попадает ли VM под исключение
is_excluded() {
    local iface="$1"
    # Пропускаем исключенные VM
    if [[ "$iface" =~ ^vm([0-9]+)_net0$ ]]; then
        local vm_id="${BASH_REMATCH[1]}"
        for ex in "${EXCLUDE_IDS[@]}"; do
            if [[ "$vm_id" == "$ex" ]]; then
                return 0
            fi
        done
    fi
    # Пропускаем физические интерфейсы из списка
    for exif in "${EXCLUDE_IFACES[@]}"; do
        if [[ "$iface" == "$exif" ]]; then
            return 0
        fi
    done
    return 1
}

# Загрузка накопленных данных\load_usage_db() {
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
    tc qdisc add dev "$dev" parent 1:10 handle 10: sfq
    tc qdisc add dev "$dev" parent 1:20 handle 20: sfq

    tc qdisc add dev "$dev" ingress handle ffff:
    tc filter add dev "$dev" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$ifb"

    tc qdisc add dev "$ifb" root handle 1: htb default 20
    tc class add dev "$ifb" parent 1: classid 1:10 htb rate $DEFAULT_RATE ceil $DEFAULT_RATE
    tc class add dev "$ifb" parent 1: classid 1:20 htb rate $max_rate ceil $max_rate
    tc qdisc add dev "$ifb" parent 1:10 handle 10: sfq
    tc qdisc add dev "$ifb" parent 1:20 handle 20: sfq
}

# Проверка наличия фильтра prio 20
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

# Получение статистики\get_sent_bytes() {
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
    # Пропускаем исключённые интерфейсы
    if is_excluded "$iface"; then
        echo "Пропускаем исключённый интерфейс $iface"
        continue
    fi

    IFB_IF="ifb_${iface}"
    [ ! -d "/sys/class/net/$IFB_IF" ] && ip link add "$IFB_IF" type ifb
    ip link set dev "$IFB_IF" up

    setup_tc "$iface" "$IFB_IF" "$GLOBAL_MAX_RATE"
done

# Основной цикл учёта и контроля
while true; do
    for iface in $INTERFACES; do
        if is_excluded "$iface"; then
            continue
        fi

        IFB_IF="ifb_${iface}"

        # Ежедневная проверка наличия prio 20
        if ! filter20_exists "$iface"; then
            echo "Фильтр 1:20 отсутствует на $iface — пересоздаем правила"
            setup_tc "$iface" "$IFB_IF" "$GLOBAL_MAX_RATE"
            continue
        fi

        # Подсчет трафика
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
