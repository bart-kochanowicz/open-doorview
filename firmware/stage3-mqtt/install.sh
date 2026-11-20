#!/bin/sh
set -eu

stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-100}

module_dir=$root/etc/doorview
init_dir=$root/etc/init.d
module=$module_dir/syslink_net_irq.ko
previous_module=$module_dir/syslink_net_irq.ko.previous
daemon=$module_dir/doorview-mqtt
hook=$init_dir/S97doorview-mqtt

# The exact driver this update replaces (installed by rh-pd10-lcd-irq-20261119).
old_module_sha=a3021d63c3f97c160a8187b2a780151a3b2b9b97ac1477416e99aacc68e06156

stage_files='syslink_net_irq.ko doorview-mqtt S97doorview-mqtt'

digest() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

free_kb() {
    if [ -n "${DOORVIEW_FREE_KB:-}" ]; then
        echo "$DOORVIEW_FREE_KB"
    else
        df -k /overlay | awk 'NR == 2 { print $4 }'
    fi
}

absent() {
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

awk '
    $2 == "/" && $3 == "overlay" { root_overlay = 1 }
    $1 == "/dev/mtdblock5" && $2 == "/overlay" && $3 == "jffs2" { data = 1 }
    $2 == "/etc" || $2 == "/etc/doorview" || $2 == "/etc/init.d" { masked = 1 }
    END { exit !(root_overlay && data && !masked) }
' "$mounts"

[ -d "$module_dir" ] && [ ! -L "$module_dir" ] || exit 1
[ -d "$init_dir" ] && [ ! -L "$init_dir" ] || exit 1
for name in $stage_files; do
    [ -f "$stage/$name" ] && [ ! -L "$stage/$name" ] || exit 1
done
[ -f "$stage/SHA256SUMS" ] || exit 1
while read -r sum name; do
    [ "$(digest "$stage/$name")" = "$sum" ] || exit 1
done < "$stage/SHA256SUMS"

# Update only the exact driver that was tested, and never overwrite other state.
[ "$(digest "$module")" = "$old_module_sha" ] || exit 1
absent "$previous_module" && absent "$daemon" && absent "$hook" || exit 1
[ "$(free_kb)" -ge "$minimum_free_kb" ] || exit 1

module_tmp=
hook_tmp=
previous_done=no
module_done=no
daemon_done=no
hook_done=no
committed=no

cleanup() {
    result=$?
    set +e
    if [ "$committed" = no ]; then
        [ "$hook_done" = no ] || rm -f "$hook"
        [ "$daemon_done" = no ] || rm -f "$daemon"
        if [ "$module_done" = yes ]; then
            restore_tmp=$(mktemp "$module_dir/.restore.XXXXXX")
            if cp "$previous_module" "$restore_tmp" && chmod 600 "$restore_tmp" && mv "$restore_tmp" "$module"; then
                :
            else
                rm -f "$restore_tmp"
                echo 'ROLLBACK_FAILED: restore syslink_net_irq.ko from syslink_net_irq.ko.previous' >&2
            fi
        fi
        [ "$previous_done" = no ] || rm -f "$previous_module"
    fi
    [ -z "$module_tmp" ] || rm -rf "$module_tmp"
    [ -z "$hook_tmp" ] || rm -f "$hook_tmp"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

module_tmp=$(mktemp -d "$module_dir/.mqtt-install.XXXXXX")
hook_tmp=$(mktemp "$init_dir/.doorview.XXXXXX")

cp "$stage/syslink_net_irq.ko" "$module_tmp/syslink_net_irq.ko"
cmp -s "$stage/syslink_net_irq.ko" "$module_tmp/syslink_net_irq.ko"
chmod 600 "$module_tmp/syslink_net_irq.ko"
cp "$stage/doorview-mqtt" "$module_tmp/doorview-mqtt"
cmp -s "$stage/doorview-mqtt" "$module_tmp/doorview-mqtt"
chmod 700 "$module_tmp/doorview-mqtt"
cp "$stage/S97doorview-mqtt" "$hook_tmp"
cmp -s "$stage/S97doorview-mqtt" "$hook_tmp"
chmod 755 "$hook_tmp"

# Keep the running driver outside the module path so it can be restored.
cp "$module" "$previous_module"
cmp -s "$module" "$previous_module"
chmod 600 "$previous_module"
previous_done=yes

mv "$module_tmp/syslink_net_irq.ko" "$module"
module_done=yes
mv "$module_tmp/doorview-mqtt" "$daemon"
daemon_done=yes
# The boot hook is last: it only appears once everything it needs is in place.
mv "$hook_tmp" "$hook"
hook_tmp=
hook_done=yes

cmp -s "$stage/syslink_net_irq.ko" "$module"
cmp -s "$stage/doorview-mqtt" "$daemon"
cmp -s "$stage/S97doorview-mqtt" "$hook"
[ "$(digest "$previous_module")" = "$old_module_sha" ]
sync
committed=yes
echo MQTT_INSTALLED
