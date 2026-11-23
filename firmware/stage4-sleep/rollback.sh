#!/bin/sh
set -eu

# Puts the two drivers that were installed before install.sh back (syslink_poll.ko, syslink_net_irq.ko).
root=${DOORVIEW_ROOT:-}
module_dir=$root/etc/doorview
poll=$module_dir/syslink_poll.ko
net=$module_dir/syslink_net_irq.ko
poll_previous=$poll.before-sleep
net_previous=$net.before-sleep
old_poll_sha=80cfb8bfb7497d00062cb6bfe758fd3e089d561d2405dd2e0441207ef5271304
old_net_sha=04697404536fd72aa3097d15ef1632f63d78bf968953887a32064cd98695a463

digest() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

[ -f "$poll_previous" ] && [ "$(digest "$poll_previous")" = "$old_poll_sha" ] || exit 1
[ -f "$net_previous" ] && [ "$(digest "$net_previous")" = "$old_net_sha" ] || exit 1
[ -d "$module_dir" ] && [ ! -L "$module_dir" ] || exit 1

poll_tmp=$(mktemp "$module_dir/.restore.XXXXXX")
net_tmp=$(mktemp "$module_dir/.restore.XXXXXX")
trap 'rm -f "$poll_tmp" "$net_tmp"' EXIT
cp "$poll_previous" "$poll_tmp"
cmp -s "$poll_previous" "$poll_tmp"
chmod 600 "$poll_tmp"
cp "$net_previous" "$net_tmp"
cmp -s "$net_previous" "$net_tmp"
chmod 600 "$net_tmp"

mv "$poll_tmp" "$poll"
mv "$net_tmp" "$net"
[ "$(digest "$poll")" = "$old_poll_sha" ]
[ "$(digest "$net")" = "$old_net_sha" ]
rm -f "$poll_previous" "$net_previous"
sync
echo SLEEP_ROLLED_BACK
