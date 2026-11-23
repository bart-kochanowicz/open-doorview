#!/bin/sh
set -eu

# Puts back the daemon that was installed before install.sh. The configuration (mqtt.conf) is not touched: the old
# daemon ignores the sleep keys, so they can stay.
root=${DOORVIEW_ROOT:-}
module_dir=$root/etc/doorview
daemon=$module_dir/doorview-mqtt
previous=$daemon.before-sleep
old_daemon_sha=66a866b49ef5564ad91b92a949ca1839d5ed135f2a7eeb88124ed320e7a39225

digest() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

[ -f "$previous" ] && [ "$(digest "$previous")" = "$old_daemon_sha" ] || exit 1
[ -d "$module_dir" ] && [ ! -L "$module_dir" ] || exit 1

restore_tmp=$(mktemp "$module_dir/.restore.XXXXXX")
trap 'rm -f "$restore_tmp"' EXIT
cp "$previous" "$restore_tmp"
cmp -s "$previous" "$restore_tmp"
chmod 700 "$restore_tmp"
mv "$restore_tmp" "$daemon"
[ "$(digest "$daemon")" = "$old_daemon_sha" ]
rm -f "$previous"
sync
echo SLEEP_DAEMON_ROLLED_BACK
