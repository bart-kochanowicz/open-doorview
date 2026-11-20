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
while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$(printf '\r')"}
    case "$line" in
        ''|'#'*) ;;
        host=*) host=${line#host=} ;;
        port=*) port=${line#port=} ;;
        user=*) user=${line#user=} ;;
        password=*) password=${line#password=} ;;
        node=*|name=*|discovery=*|keepalive=*|wifi_watchdog=*) ;;
        *) echo "unknown key in configuration" >&2; exit 1 ;;
    esac
done < "$source_file"

printf '%s\n' "$host" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo 'host must be an IPv4 address' >&2; exit 1; }
[ "${port:-1883}" -ge 1 ] 2> /dev/null && [ "${port:-1883}" -le 65535 ] || { echo 'bad port' >&2; exit 1; }
[ -n "$user" ] && [ -n "$password" ] || { echo 'user and password are required' >&2; exit 1; }
[ "${#password}" -lt 64 ] && [ "${#user}" -lt 64 ] || { echo 'user or password too long' >&2; exit 1; }

tmp=$(mktemp "$target_dir/.mqtt-conf.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat "$source_file" > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$target"
sync
echo MQTT_CONFIGURED
