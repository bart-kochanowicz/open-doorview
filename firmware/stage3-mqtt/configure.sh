#!/bin/sh
set -eu

# Installs the broker configuration. Usage: configure.sh <file> [--replace]
# The file holds credentials, so it must arrive through the silent UART upload, never through a command line.
source_file=$1
replace=${2:-}
root=${DOORVIEW_ROOT:-}
target=$root/etc/doorview/mqtt.conf
target_dir=$root/etc/doorview

[ -f "$source_file" ] && [ ! -L "$source_file" ] || exit 1
[ -d "$target_dir" ] && [ ! -L "$target_dir" ] || exit 1
if [ -e "$target" ] || [ -L "$target" ]; then
    [ "$replace" = --replace ] || { echo 'mqtt.conf exists; pass --replace to overwrite it' >&2; exit 1; }
fi

host=
port=
user=
password=
gateway=
motion=
motion_port=
motion_hold=
snapshot=
snapshot_path=
snapshot_cooldown=
while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$(printf '\r')"}
    case "$line" in
        ''|'#'*) ;;
        host=*) host=${line#host=} ;;
        port=*) port=${line#port=} ;;
        user=*) user=${line#user=} ;;
        password=*) password=${line#password=} ;;
        gateway=*) gateway=${line#gateway=} ;;
        motion=*) motion=${line#motion=} ;;
        motion_port=*) motion_port=${line#motion_port=} ;;
        motion_hold=*) motion_hold=${line#motion_hold=} ;;
        snapshot=*) snapshot=${line#snapshot=} ;;
        snapshot_path=*) snapshot_path=${line#snapshot_path=} ;;
        snapshot_cooldown=*) snapshot_cooldown=${line#snapshot_cooldown=} ;;
        node=*|name=*|discovery=*|keepalive=*|wifi_watchdog=*) ;;
        *) echo "unknown key in configuration" >&2; exit 1 ;;
    esac
done < "$source_file"

printf '%s\n' "$host" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo 'host must be an IPv4 address' >&2; exit 1; }
[ "${port:-1883}" -ge 1 ] 2> /dev/null && [ "${port:-1883}" -le 65535 ] || { echo 'bad port' >&2; exit 1; }
[ -z "$gateway" ] || printf '%s\n' "$gateway" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo 'gateway must be an IPv4 address' >&2; exit 1; }
case "$motion" in ''|0|1) ;; *) echo 'motion must be 0 or 1' >&2; exit 1 ;; esac
[ -z "$motion_port" ] || { printf '%s\n' "$motion_port" | grep -Eq '^[0-9]{1,5}$' && [ "$motion_port" -ge 1 ] && [ "$motion_port" -le 65535 ]; } || { echo 'bad motion_port' >&2; exit 1; }
[ -z "$motion_hold" ] || { printf '%s\n' "$motion_hold" | grep -Eq '^[0-9]{1,3}$' && [ "$motion_hold" -ge 1 ] && [ "$motion_hold" -le 600 ]; } || { echo 'bad motion_hold' >&2; exit 1; }
case "$snapshot" in ''|0|1) ;; *) echo 'snapshot must be 0 or 1' >&2; exit 1 ;; esac
[ "$snapshot" != 1 ] || [ "$motion" = 1 ] || { echo 'snapshot=1 needs motion=1' >&2; exit 1; }
[ -z "$snapshot_path" ] || printf '%s\n' "$snapshot_path" | grep -Eq '^/[A-Za-z0-9/._?&=%-]{0,120}$' || { echo 'bad snapshot_path' >&2; exit 1; }
[ -z "$snapshot_cooldown" ] || { printf '%s\n' "$snapshot_cooldown" | grep -Eq '^[0-9]{1,4}$' && [ "$snapshot_cooldown" -ge 1 ] && [ "$snapshot_cooldown" -le 3600 ]; } || { echo 'bad snapshot_cooldown' >&2; exit 1; }
[ -n "$user" ] && [ -n "$password" ] || { echo 'user and password are required' >&2; exit 1; }
[ "${#password}" -lt 64 ] && [ "${#user}" -lt 64 ] || { echo 'user or password too long' >&2; exit 1; }

tmp=$(mktemp "$target_dir/.mqtt-conf.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat "$source_file" > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$target"
sync
echo MQTT_CONFIGURED
