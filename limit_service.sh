#!/bin/bash

DEFAULT_RATE="1mbit"       # скорость ограниченного класса 10
MAX_RATE="1000mbit"        # максимальная скорость класса 20

INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vm[0-9]+_net0$')

modprobe ifb

for iface in $INTERFACES; do
    IFB_IF="ifb_${iface}"

    

    # Создаем ifb интерфейс, если отсутствует
    if ! ip link show dev $IFB_IF &>/dev/null; then
        ip link add $IFB_IF type ifb
    fi

    ip link set dev $IFB_IF up

    # Удаляем старые qdisc
    /sbin/tc qdisc del dev $iface root 2>/dev/null
    /sbin/tc qdisc del dev $iface ingress 2>/dev/null
    /sbin/tc qdisc del dev $IFB_IF root 2>/dev/null

    # Исходящий трафик: root htb с двумя классами, дефолт 20 (максимум)
    /sbin/tc qdisc add dev $iface root handle 1: htb default 20
    /sbin/tc class add dev $iface parent 1: classid 1:10 htb rate $DEFAULT_RATE ceil $DEFAULT_RATE
    /sbin/tc class add dev $iface parent 1: classid 1:20 htb rate $MAX_RATE ceil $MAX_RATE

    # Входящий трафик через ifb с теми же классами и дефолтом 20
    /sbin/tc qdisc add dev $iface ingress handle ffff:
    /sbin/tc filter add dev $iface parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev $IFB_IF

    /sbin/tc qdisc add dev $IFB_IF root handle 1: htb default 20
    /sbin/tc class add dev $IFB_IF parent 1: classid 1:10 htb rate $DEFAULT_RATE ceil $DEFAULT_RATE
    /sbin/tc class add dev $IFB_IF parent 1: classid 1:20 htb rate $MAX_RATE ceil $MAX_RATE
done


LIMIT_BYTES=$((25 * 1024 * 1024 * 1024)) #  в байтах
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vm[0-9]+_net0$')

declare -A limited_ifaces  # associative array для хранения флагов лимита

get_sent_bytes() {
    local dev=$1
    local classid=$2
    /sbin/tc -s class show dev "$dev" | awk -v cid="$classid" '
        $1=="class" && $3==cid {
            in_class=1
        }
        in_class && $1=="Sent" {
            for(i=1;i<=NF;i++) {
                if($i=="bytes") {
                    print $(i-1)
                    exit
                }
            }
        }
        $1=="class" && $3!=cid {
            in_class=0
        }
    '
}

filter_exists() {
    local dev=$1
    local prio=1000
    /sbin/tc filter show dev "$dev" parent 1: | grep -q "priority $prio .*classid 1:10"
}

add_filter_to_10() {
    local dev=$1
    local prio=1000
   
    /sbin/tc filter add dev "$dev" protocol ip parent 1: prio $prio u32 match u32 0 0 flowid 1:10
}

while true; do
    for iface in $INTERFACES; do
        IFB_IF="ifb_${iface}"

        if ! ip link show dev $IFB_IF &>/dev/null; then
            echo "$iface: ifb интерфейс $IFB_IF не найден — пропускаем"
            continue
        fi

        out_bytes_20=$(get_sent_bytes "$iface" "1:20")
        in_bytes_20=$(get_sent_bytes "$IFB_IF" "1:20")

        out_bytes_20=${out_bytes_20:-0}
        in_bytes_20=${in_bytes_20:-0}

        total_20=$((out_bytes_20 + in_bytes_20))

        # Проверяем, применён ли лимит в памяти
        if [ "${limited_ifaces[$iface]}" != "1" ]; then
            if [ "$total_20" -gt "$LIMIT_BYTES" ]; then
                sleep 0.01

                if ! filter_exists "$iface"; then
                    add_filter_to_10 "$iface"
                else
                    sleep 0.01
                fi

                if ! filter_exists "$IFB_IF"; then
                    add_filter_to_10 "$IFB_IF"
                else
                    sleep 0.01
                fi

                limited_ifaces[$iface]=1
            else
                sleep 0.01
            fi
        else
            sleep 0.01
        fi

        sleep 0.2
    done
done
