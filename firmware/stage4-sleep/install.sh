#!/bin/sh
set -eu

# Replaces two drivers: syslink_poll.ko (accepts every wake-up reason, not only poweron) and
# syslink_net_irq.ko (adds the write-only "mcu" and "standby" parameters). Nothing starts by itself:
# no boot hook is added or changed, and the old files are kept as *.before-sleep for rollback.sh.
stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-100}

module_dir=$root/etc/doorview
init_dir=$root/etc/init.d
poll=$module_dir/syslink_poll.ko
net=$module_dir/syslink_net_irq.ko
poll_previous=$poll.before-sleep
net_previous=$net.before-sleep

# The exact drivers this update replaces (the shipped, camera-tested builds).
old_poll_sha=80cfb8bfb7497d00062cb6bfe758fd3e089d561d2405dd2e0441207ef5271304
old_net_sha=04697404536fd72aa3097d15ef1632f63d78bf968953887a32064cd98695a463

stage_files='syslink_poll.ko syslink_net_irq.ko'

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
[ -f "$poll" ] && [ ! -L "$poll" ] && [ "$(digest "$poll")" = "$old_poll_sha" ] || exit 1
[ -f "$net" ] && [ ! -L "$net" ] && [ "$(digest "$net")" = "$old_net_sha" ] || exit 1
absent "$poll_previous" && absent "$net_previous" || exit 1
[ "$(free_kb)" -ge "$minimum_free_kb" ] || exit 1

work=
poll_previous_done=no
net_previous_done=no
poll_done=no
net_done=no
committed=no
restore_failed=no

restore_one() {
    # $1 = installed file, $2 = its .before-sleep copy
    restore_tmp=$(mktemp "$module_dir/.restore.XXXXXX") || return 1
    if cp "$2" "$restore_tmp" && chmod 600 "$restore_tmp" && mv "$restore_tmp" "$1"; then
        return 0
    fi
    rm -f "$restore_tmp"
    return 1
}

cleanup() {
    result=$?
    set +e
    if [ "$committed" = no ]; then
        if [ "$poll_done" = yes ] && ! restore_one "$poll" "$poll_previous"; then
            restore_failed=yes
            echo 'ROLLBACK_FAILED: restore syslink_poll.ko from syslink_poll.ko.before-sleep' >&2
        fi
        if [ "$net_done" = yes ] && ! restore_one "$net" "$net_previous"; then
            restore_failed=yes
            echo 'ROLLBACK_FAILED: restore syslink_net_irq.ko from syslink_net_irq.ko.before-sleep' >&2
        fi
        # A backup is the only copy of the old driver if its restore failed: keep both for a manual restore.
        if [ "$restore_failed" = no ]; then
            [ "$poll_previous_done" = no ] || rm -f "$poll_previous"
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
    chmod 600 "$work/$name"
done

# Keep the running drivers outside the module path so that they can be restored.
cp "$poll" "$poll_previous"
cmp -s "$poll" "$poll_previous"
chmod 600 "$poll_previous"
poll_previous_done=yes
cp "$net" "$net_previous"
cmp -s "$net" "$net_previous"
chmod 600 "$net_previous"
net_previous_done=yes

mv "$work/syslink_poll.ko" "$poll"
poll_done=yes
mv "$work/syslink_net_irq.ko" "$net"
net_done=yes

cmp -s "$stage/syslink_poll.ko" "$poll"
cmp -s "$stage/syslink_net_irq.ko" "$net"
[ "$(digest "$poll_previous")" = "$old_poll_sha" ]
[ "$(digest "$net_previous")" = "$old_net_sha" ]
sync
committed=yes
echo SLEEP_INSTALLED
