#!/bin/bash

DEFAULT_RATE="1200kbit"
MAX_RATE="800mbit"
LIMIT_BYTES=$((1 * 1024 * 1024 * 1024)) # 25 ГБ

INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vm[0-9]+_net0$')

modprobe ifb

DB_FILE="/tmp/iface_usage.db"
> "$DB_FILE"  # сброс статистики при первом запуске

declare -A limited_ifaces
declare -A last_bytes_20

setup_tc() {
    local dev=$1
    local ifb=$2

    tc qdisc del dev "$dev" root 2>/dev/null
    tc qdisc del dev "$dev" ingress 2>/dev/null
    tc qdisc del dev "$ifb" root 2>/dev/null

    tc qdisc add dev "$dev" root handle 1: htb default 20
    tc class add dev "$dev" parent 1: classid 1:10 htb rate $DEFAULT_RATE ceil $DEFAULT_RATE
    tc class add dev "$dev" parent 1: classid 1:20 htb rate $MAX_RATE ceil $MAX_RATE
    tc qdisc add dev "$dev" parent 1:10 handle 10: sfq

    tc qdisc add dev "$dev" ingress handle ffff:
    tc filter add dev "$dev" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$ifb"

    tc qdisc add dev "$ifb" root handle 1: htb default 20
    tc class add dev "$ifb" parent 1: classid 1:10 htb rate $DEFAULT_RATE ceil $DEFAULT_RATE
    tc class add dev "$ifb" parent 1: classid 1:20 htb rate $MAX_RATE ceil $MAX_RATE
    tc qdisc add dev "$ifb" parent 1:10 handle 10: sfq
}

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

has_class_20() {
    local dev=$1
    tc class show dev "$dev" | grep -q "class htb 1:20"
}

filter_exists() {
    local dev=$1
    local prio=1000
    tc filter show dev "$dev" parent 1: | grep -q "priority $prio .*classid 1:10"
}

add_filter_to_10() {
    local dev=$1
    local prio=1000
    tc filter add dev "$dev" protocol ip parent 1: prio $prio u32 match u32 0 0 flowid 1:10
}

# Начальная настройка
for iface in $INTERFACES; do
    IFB_IF="ifb_${iface}"

    if ! ip link show dev $IFB_IF &>/dev/null; then
        ip link add $IFB_IF type ifb
    fi
    ip link set dev $IFB_IF up
    setup_tc "$iface" "$IFB_IF"
done

# Основной цикл
while true; do
    for iface in $INTERFACES; do
        IFB_IF="ifb_${iface}"

        # Проверка qdisc и наличия класса 1:20
        if ! tc qdisc show dev "$iface" | grep -q "htb 1:" || ! has_class_20 "$iface"; then
            setup_tc "$iface" "$IFB_IF"
        fi
        if ! tc qdisc show dev "$IFB_IF" | grep -q "htb 1:" || ! has_class_20 "$IFB_IF"; then
            setup_tc "$iface" "$IFB_IF"
        fi

        if ! ip link show dev "$IFB_IF" &>/dev/null; then
            echo "$iface: IFB $IFB_IF не найден"
            continue
        fi

        out_bytes=$(get_sent_bytes "$iface" "1:20")
        in_bytes=$(get_sent_bytes "$IFB_IF" "1:20")

        out_bytes=${out_bytes:-0}
        in_bytes=${in_bytes:-0}

        total_raw=$((out_bytes + in_bytes))

        # Чтение предыдущего значения
        prev=$(grep "^$iface=" "$DB_FILE" | cut -d= -f2)
        prev=${prev:-0}

        if [ "$total_raw" -lt "$prev" ]; then
            total_bytes=$((total_raw + prev))
        else
            total_bytes=$((total_raw - prev + prev))
        fi

        # Обновление статистики
        grep -v "^$iface=" "$DB_FILE" > "${DB_FILE}.tmp"
        echo "$iface=$total_bytes" >> "${DB_FILE}.tmp"
        mv "${DB_FILE}.tmp" "$DB_FILE"

        # Лимит трафика
        if [ "$total_bytes" -gt "$LIMIT_BYTES" ]; then
            prev_check=${last_bytes_20["$iface"]}
            if [ -z "$prev_check" ] || [ "$prev_check" -ne "$total_raw" ]; then
                echo "$iface: превышен лимит — перенаправляем в класс 1:10"
                if ! filter_exists "$iface"; then
                    add_filter_to_10 "$iface"
                fi
                if ! filter_exists "$IFB_IF"; then
                    add_filter_to_10 "$IFB_IF"
                fi
                last_bytes_20["$iface"]=$total_raw
            else
                echo "$iface: лимит уже применён, трафик не растёт"
            fi
        fi

        sleep 0.2
    done
done
