#!/bin/sh
set -eu

# Removes what install.sh added: the two boot hooks and the three SDIO modules. It only removes a file whose
# content still matches the staged copy, so a file you changed yourself is left alone and reported.
# The Wi-Fi configuration (station.hex, address, mac) is kept unless you pass --purge-config.
# The (then empty) /etc/doorview directory is left in place; it is harmless and later stages expect it.
# Usage: rollback.sh <directory with the staged files> [--purge-config]

stage=$1
purge=${2:-}
root=${DOORVIEW_ROOT:-}
module_dir=$root/etc/doorview
init_dir=$root/etc/init.d

digest() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

[ -f "$stage/SHA256SUMS" ] || exit 1

# Check everything before removing anything.
for name in S41doorview-network S39doorview; do
    expected=$(grep " $name\$" "$stage/SHA256SUMS" | cut -d' ' -f1)
    [ -n "$expected" ] || exit 1
    if [ -e "$init_dir/$name" ]; then
        [ "$(digest "$init_dir/$name")" = "$expected" ] || { echo "$name was modified; refusing" >&2; exit 1; }
    fi
done
for name in syslink_net.ko syslink_bg.ko syslink_poll.ko; do
    expected=$(grep " $name\$" "$stage/SHA256SUMS" | cut -d' ' -f1)
    [ -n "$expected" ] || exit 1
    if [ -e "$module_dir/$name" ]; then
        [ "$(digest "$module_dir/$name")" = "$expected" ] || { echo "$name was modified; refusing" >&2; exit 1; }
    fi
done

# The startup hooks first, so nothing starts the modules while they are being removed.
rm -f "$init_dir/S41doorview-network" "$init_dir/S39doorview"
rm -f "$module_dir/syslink_net.ko" "$module_dir/syslink_bg.ko" "$module_dir/syslink_poll.ko"
if [ "$purge" = --purge-config ]; then
    rm -f "$module_dir/station.hex" "$module_dir/address" "$module_dir/mac"
fi
sync
echo WIFI_BASE_ROLLED_BACK
