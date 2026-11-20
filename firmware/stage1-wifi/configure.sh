#!/bin/sh
set -eu

# Installs the Wi-Fi configuration prepared on your computer by tools/make-wifi-config.py.
# Usage: configure.sh <directory with station.hex, address and mac> [--replace]
# station.hex is equivalent to your Wi-Fi password: upload the directory with the silent UART upload
# (tools/upload-archive.py), never through a command line, and delete it afterwards.

source_dir=$1
replace=${2:-}
root=${DOORVIEW_ROOT:-}
target_dir=$root/etc/doorview

[ -d "$target_dir" ] && [ ! -L "$target_dir" ] || exit 1
for name in station.hex address mac; do
    [ -f "$source_dir/$name" ] && [ ! -L "$source_dir/$name" ] || exit 1
    if [ -e "$target_dir/$name" ] || [ -L "$target_dir/$name" ]; then
        [ "$replace" = --replace ] || { echo "$name exists; pass --replace to overwrite it" >&2; exit 1; }
    fi
done

# Same checks as the startup script, so a bad file is refused now instead of failing at boot.
case $(wc -c < "$source_dir/station.hex" | tr -d '[:space:]') in
    128|129) ;;
    *) echo 'station.hex must be 128 hex characters' >&2; exit 1 ;;
esac
grep -Eq '^[0-9a-fA-F]{128}$' "$source_dir/station.hex" || { echo 'station.hex must be 128 hex characters' >&2; exit 1; }
# The drivers reject an empty SSID or passphrase and a field whose last byte is not NUL.
station=$(tr -d '[:space:]' < "$source_dir/station.hex")
[ "$(printf '%s' "$station" | cut -c1-2)" != 00 ] && [ "$(printf '%s' "$station" | cut -c65-66)" != 00 ] &&
    [ "$(printf '%s' "$station" | cut -c63-64)" = 00 ] && [ "$(printf '%s' "$station" | cut -c127-128)" = 00 ] ||
    { echo 'station.hex fields must be non-empty and shorter than 32 bytes' >&2; exit 1; }
read -r address < "$source_dir/address" || exit 1
read -r mac < "$source_dir/mac" || exit 1
printf '%s\n' "$address" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$' || { echo 'address must be an IPv4 address with a prefix length' >&2; exit 1; }
printf '%s\n' "$mac" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || { echo 'mac must be six colon-separated hex bytes' >&2; exit 1; }

tmp_dir=$(mktemp -d "$target_dir/.wifi-conf.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
for name in station.hex address mac; do
    cp "$source_dir/$name" "$tmp_dir/$name"
    chmod 600 "$tmp_dir/$name"
done
for name in station.hex address mac; do
    mv "$tmp_dir/$name" "$target_dir/$name"
done
sync
echo WIFI_CONFIGURED
