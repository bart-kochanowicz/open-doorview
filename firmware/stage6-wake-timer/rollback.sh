#!/bin/sh
set -eu

# Puts the daemon and the network driver that were installed before install.sh back.
root=${DOORVIEW_ROOT:-}
module_dir=$root/etc/doorview
daemon=$module_dir/doorview-mqtt
net=$module_dir/syslink_net_irq.ko
daemon_previous=$daemon.before-timer
net_previous=$net.before-timer
old_daemon_sha=c8a2f34cc9b6237839beb5fa1593bb7a3ffb641b21c80adda47a683908d9d921
old_net_sha=79da5f24ffe14d216b00a8049be6026d20dec7a8db1cb8e724878200fff27b6e

digest() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

[ -f "$daemon_previous" ] && [ "$(digest "$daemon_previous")" = "$old_daemon_sha" ] || exit 1
[ -f "$net_previous" ] && [ "$(digest "$net_previous")" = "$old_net_sha" ] || exit 1
[ -d "$module_dir" ] && [ ! -L "$module_dir" ] || exit 1

daemon_tmp=$(mktemp "$module_dir/.restore.XXXXXX")
net_tmp=$(mktemp "$module_dir/.restore.XXXXXX")
trap 'rm -f "$daemon_tmp" "$net_tmp"' EXIT
cp "$daemon_previous" "$daemon_tmp"
cmp -s "$daemon_previous" "$daemon_tmp"
chmod 700 "$daemon_tmp"
cp "$net_previous" "$net_tmp"
cmp -s "$net_previous" "$net_tmp"
chmod 600 "$net_tmp"

mv "$daemon_tmp" "$daemon"
mv "$net_tmp" "$net"
[ "$(digest "$daemon")" = "$old_daemon_sha" ]
[ "$(digest "$net")" = "$old_net_sha" ]
rm -f "$daemon_previous" "$net_previous"
sync
echo TIMER_ROLLED_BACK
