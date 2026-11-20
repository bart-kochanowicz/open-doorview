#!/bin/sh
set -eu

# Restores the driver that was installed before install.sh and removes the MQTT daemon and its boot hook.
# The configuration /etc/doorview/mqtt.conf (credentials) is left in place; remove it separately if wanted.
root=${DOORVIEW_ROOT:-}
module_dir=$root/etc/doorview
init_dir=$root/etc/init.d
module=$module_dir/syslink_net_irq.ko
previous_module=$module_dir/syslink_net_irq.ko.previous
daemon=$module_dir/doorview-mqtt
hook=$init_dir/S97doorview-mqtt
old_module_sha=a3021d63c3f97c160a8187b2a780151a3b2b9b97ac1477416e99aacc68e06156

digest() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

[ -f "$previous_module" ] && [ "$(digest "$previous_module")" = "$old_module_sha" ] || exit 1
[ -d "$module_dir" ] && [ ! -L "$module_dir" ] || exit 1

restore_tmp=$(mktemp "$module_dir/.restore.XXXXXX")
trap 'rm -f "$restore_tmp"' EXIT
cp "$previous_module" "$restore_tmp"
cmp -s "$previous_module" "$restore_tmp"
chmod 600 "$restore_tmp"

# Stop the boot hook first, then put the previous driver back.
[ ! -x "$hook" ] || sh "$hook" stop || true
rm -f "$hook"
mv "$restore_tmp" "$module"
[ "$(digest "$module")" = "$old_module_sha" ]
rm -f "$daemon" "$previous_module"
sync
echo MQTT_ROLLED_BACK
