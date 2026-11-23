#!/bin/sh
set -eu

# Replaces the MQTT daemon with the build that can put the camera to sleep (sleep_after in mqtt.conf). The sleep is
# off until that key is added, so the new daemon behaves like the old one by default. The old daemon is kept as
# doorview-mqtt.before-sleep for rollback.sh. No hook and no configuration file is touched.
stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-100}

module_dir=$root/etc/doorview
init_dir=$root/etc/init.d
daemon=$module_dir/doorview-mqtt
previous=$daemon.before-sleep

# The exact daemon this update replaces (the build that ran on the camera with the live view).
old_daemon_sha=66a866b49ef5564ad91b92a949ca1839d5ed135f2a7eeb88124ed320e7a39225

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
[ -f "$stage/doorview-mqtt" ] && [ ! -L "$stage/doorview-mqtt" ] || exit 1
[ -f "$stage/SHA256SUMS" ] || exit 1
while read -r sum name; do
    [ "$(digest "$stage/$name")" = "$sum" ] || exit 1
done < "$stage/SHA256SUMS"
# Every file that gets installed must have an entry: an empty or short manifest must not skip verification.
awk '$2 == "doorview-mqtt" { found = 1 } END { exit !found }' "$stage/SHA256SUMS" || exit 1

# Update only the exact daemon that was tested, and never overwrite other state.
[ -f "$daemon" ] && [ ! -L "$daemon" ] && [ "$(digest "$daemon")" = "$old_daemon_sha" ] || exit 1
absent "$previous" || exit 1
[ "$(free_kb)" -ge "$minimum_free_kb" ] || exit 1

work=
previous_done=no
daemon_done=no
committed=no
restore_failed=no

cleanup() {
    result=$?
    set +e
    if [ "$committed" = no ]; then
        if [ "$daemon_done" = yes ]; then
            restore_tmp=$(mktemp "$module_dir/.restore.XXXXXX")
            if [ -n "$restore_tmp" ] && cp "$previous" "$restore_tmp" && chmod 700 "$restore_tmp" && mv "$restore_tmp" "$daemon"; then
                :
            else
                rm -f "$restore_tmp"
                restore_failed=yes
                echo 'ROLLBACK_FAILED: restore doorview-mqtt from doorview-mqtt.before-sleep' >&2
            fi
        fi
        # The backup is the only copy of the old daemon if the restore failed: keep it for a manual restore.
        [ "$previous_done" = no ] || [ "$restore_failed" = yes ] || rm -f "$previous"
    fi
    [ -z "$work" ] || rm -rf "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

work=$(mktemp -d "$module_dir/.sleep-daemon-install.XXXXXX")
cp "$stage/doorview-mqtt" "$work/doorview-mqtt"
cmp -s "$stage/doorview-mqtt" "$work/doorview-mqtt"
chmod 700 "$work/doorview-mqtt"

# Keep the running daemon outside its path so that it can be restored.
cp "$daemon" "$previous"
cmp -s "$daemon" "$previous"
chmod 700 "$previous"
previous_done=yes

mv "$work/doorview-mqtt" "$daemon"
daemon_done=yes

cmp -s "$stage/doorview-mqtt" "$daemon"
[ "$(digest "$previous")" = "$old_daemon_sha" ]
sync
committed=yes
echo SLEEP_DAEMON_INSTALLED
