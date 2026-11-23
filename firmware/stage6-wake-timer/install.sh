#!/bin/sh
set -eu

# Replaces the MQTT daemon (wake_timer: it tells the coprocessor not to wake the camera by its own timer) and
# syslink_net_irq.ko (the mcu parameter also accepts the wake-up timer, 0x7b). The daemon does nothing new unless
# sleep_after is set. No boot hook or configuration file is touched; the old files are kept as *.before-timer for
# rollback.sh.
stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-100}

module_dir=$root/etc/doorview
init_dir=$root/etc/init.d
daemon=$module_dir/doorview-mqtt
net=$module_dir/syslink_net_irq.ko
daemon_previous=$daemon.before-timer
net_previous=$net.before-timer

# The exact drivers this update replaces (the shipped, camera-tested builds).
old_daemon_sha=c8a2f34cc9b6237839beb5fa1593bb7a3ffb641b21c80adda47a683908d9d921
old_net_sha=79da5f24ffe14d216b00a8049be6026d20dec7a8db1cb8e724878200fff27b6e

stage_files='doorview-mqtt syslink_net_irq.ko'

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
# Every file that gets installed must have an entry: an empty or short manifest must not skip verification.
for name in $stage_files; do
    awk -v wanted="$name" '$2 == wanted { found = 1 } END { exit !found }' "$stage/SHA256SUMS" || exit 1
done

# Update only the exact drivers that were tested, and never overwrite other state.
[ -f "$daemon" ] && [ ! -L "$daemon" ] && [ "$(digest "$daemon")" = "$old_daemon_sha" ] || exit 1
[ -f "$net" ] && [ ! -L "$net" ] && [ "$(digest "$net")" = "$old_net_sha" ] || exit 1
absent "$daemon_previous" && absent "$net_previous" || exit 1
[ "$(free_kb)" -ge "$minimum_free_kb" ] || exit 1

work=
daemon_previous_done=no
net_previous_done=no
daemon_done=no
net_done=no
committed=no
restore_failed=no

restore_one() {
    # $1 = installed file, $2 = its .before-timer copy, $3 = its mode
    restore_tmp=$(mktemp "$module_dir/.restore.XXXXXX") || return 1
    if cp "$2" "$restore_tmp" && chmod "$3" "$restore_tmp" && mv "$restore_tmp" "$1"; then
        return 0
    fi
    rm -f "$restore_tmp"
    return 1
}

cleanup() {
    result=$?
    set +e
    if [ "$committed" = no ]; then
        if [ "$daemon_done" = yes ] && ! restore_one "$daemon" "$daemon_previous" 700; then
            restore_failed=yes
            echo 'ROLLBACK_FAILED: restore doorview-mqtt from doorview-mqtt.before-timer' >&2
        fi
        if [ "$net_done" = yes ] && ! restore_one "$net" "$net_previous" 600; then
            restore_failed=yes
            echo 'ROLLBACK_FAILED: restore syslink_net_irq.ko from syslink_net_irq.ko.before-timer' >&2
        fi
        # A backup is the only copy of the old driver if its restore failed: keep both for a manual restore.
        if [ "$restore_failed" = no ]; then
            [ "$daemon_previous_done" = no ] || rm -f "$daemon_previous"
            [ "$net_previous_done" = no ] || rm -f "$net_previous"
        fi
    fi
    [ -z "$work" ] || rm -rf "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

work=$(mktemp -d "$module_dir/.sleep-install.XXXXXX")

for name in $stage_files; do
    cp "$stage/$name" "$work/$name"
    cmp -s "$stage/$name" "$work/$name"
done
chmod 700 "$work/doorview-mqtt"
chmod 600 "$work/syslink_net_irq.ko"

# Keep the running drivers outside the module path so that they can be restored.
cp "$daemon" "$daemon_previous"
cmp -s "$daemon" "$daemon_previous"
chmod 700 "$daemon_previous"
daemon_previous_done=yes
cp "$net" "$net_previous"
cmp -s "$net" "$net_previous"
chmod 600 "$net_previous"
net_previous_done=yes

mv "$work/doorview-mqtt" "$daemon"
daemon_done=yes
mv "$work/syslink_net_irq.ko" "$net"
net_done=yes

cmp -s "$stage/doorview-mqtt" "$daemon"
cmp -s "$stage/syslink_net_irq.ko" "$net"
[ "$(digest "$daemon_previous")" = "$old_daemon_sha" ]
[ "$(digest "$net_previous")" = "$old_net_sha" ]
sync
committed=yes
echo TIMER_INSTALLED
