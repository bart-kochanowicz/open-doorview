#!/bin/sh
set -eu

cd /tmp/lcd-vo-test
exec 9>preview.lock
flock -n 9
mux_state=panel-mux-before.txt
vo_log=live-vo.log
# The factory GPIO number uses decimal bank and pin. LcdEn 15 is GPIO1_5.
gpio=/sys/class/gpio/gpio13
: > "$vo_log"
backlight_owned=0
mux_changed=0
vo_pid=

cleanup() {
    result=$?
    trap - EXIT
    set +e
    if [ "$backlight_owned" = 1 ]; then
        echo 0 > "$gpio/value" || result=1
        [ "$(cat "$gpio/direction")" = out ] || result=1
        [ "$(cat "$gpio/value")" = 0 ] || result=1
    fi
    if [ -n "$vo_pid" ]; then
        wait "$vo_pid" || result=1
        cat "$vo_log"
    fi
    if [ "$mux_changed" = 1 ]; then
        while read -r addr value; do
            devmem "$addr" 32 "$value" || result=1
            [ "$(devmem "$addr" 32)" = "$value" ] || result=1
        done < "$mux_state"
    fi
    echo "Panel test and restore status: $result"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$(cat "$gpio/direction")" = out ]
[ "$(cat "$gpio/value")" = 0 ]
backlight_owned=1
: > "$mux_state"
for offset in 74 70 6c 68 58 5c 60 64 50 4c 54 48; do
    address=0x112c00$offset
    value=$(devmem "$address" 32)
    case "$offset:$value" in
        48:0x00001A30|4c:0x00001120|50:0x00001000|54:0x00001A00) ;;
        58:0x00001120|5c:0x00001120|60:0x00001120|64:0x00001120) ;;
        68:0x00001000|6c:0x00001A00|70:0x00001000|74:0x00001000) ;;
        *) echo "Unexpected pinmux state at $address: $value"; exit 1 ;;
    esac
    printf '%s %s\n' "$address" "$value" >> "$mux_state"
done

mux_changed=1
while read -r addr previous; do
    case "$addr" in
        0x112c0048|0x112c006c) value=0x00001A05 ;;
        *) value=0x00001005 ;;
    esac
    devmem "$addr" 32 "$value"
    [ "$(devmem "$addr" 32)" = "$value" ]
done < "$mux_state"

LD_PRELOAD="./libuclibc-compat.so /usr/lib/libsecurec.so /usr/lib/libvoice_engine.so /usr/lib/libupvqe.so /usr/lib/libdnvqe.so" \
    ./vo-live-30 > "$vo_log" 2>&1 &
vo_pid=$!
attempts=0
while :; do
    if grep -qs '^Live frames ready: 0x00000000$' "$vo_log" && awk '
        /^-----BySingle CHN STATUS 1/ { channel_status = 1; next }
        /^-----/ { channel_status = 0 }
        channel_status && $1 == 0 && $2 == 0 && $8 >= 3 && $12 > 0 {
            print "VO receiving and displaying:", $0
            displayed = 1
        }
        END { exit !displayed }
    ' /proc/umap/vo; then
        break
    fi
    kill -0 "$vo_pid" 2>/dev/null
    [ "$attempts" -lt 4 ]
    attempts=$((attempts + 1))
    sleep 1
done
head -10 /proc/umap/vo
echo 1 > "$gpio/value"
[ "$(devmem 0x120b1080 32)" = 0x00000020 ]
echo PANEL_ENABLED
seconds=0
while [ "$seconds" -lt 30 ] && kill -0 "$vo_pid" 2>/dev/null; do
    sleep 1
    seconds=$((seconds + 1))
done
echo 0 > "$gpio/value"
[ "$(cat "$gpio/value")" = 0 ]
echo "PANEL_DISABLED (seconds=$seconds)"
[ "$seconds" = 30 ]
