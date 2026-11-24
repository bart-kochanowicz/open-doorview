#!/bin/sh
set -eu

# The wake-up from the network (docs/remote-wake.md): /etc/doorview/syslink_net_irq.ko (the stage 12 driver with the
# coprocessor's keep-alive commands in a "wifi" parameter, and an SDIO setup that is tried again instead of giving up,
# which a boot after a wake-up from the network needs) and /etc/doorview/doorview-mqtt (the stage 13 daemon that arms
# the keep-alive before every standby when wake_server and wake_pattern are set, and starts the live view after such a
# wake-up). The configuration is not changed here. The old files are kept in /etc/doorview as <name>.before-remote for
# rollback.sh.
stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-80}

dir=$root/etc/doorview

stage_files='doorview-mqtt syslink_net_irq.ko'

# The exact files this update replaces: the stage 13 daemon and the stage 12 driver.
pin_of() {
    case "$1" in
        doorview-mqtt) echo f376c655eebf9ab7c2fd8ef76d4bbbba298b03b5528134397f9a72335cef2b79 ;;
        syslink_net_irq.ko) echo fbdc6b89903c433641b5b87e89af38a13a3b540264eb07a5bf25d29f1c2565e0 ;;
    esac
}

# The modes stages 3 and 6 installed: the daemon runs for its owner only, the module is only read.
mode_of() {
    case "$1" in
        doorview-mqtt) echo 700 ;;
        syslink_net_irq.ko) echo 600 ;;
    esac
}

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
    $2 == "/etc" || $2 == "/etc/doorview" { masked = 1 }
    END { exit !(root_overlay && data && !masked) }
' "$mounts"

[ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
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

# Update only the exact files that were tested, and never overwrite other state.
for name in $stage_files; do
    [ -f "$dir/$name" ] && [ ! -L "$dir/$name" ] && [ "$(digest "$dir/$name")" = "$(pin_of "$name")" ] || exit 1
    absent "$dir/$name.before-remote" || exit 1
done
[ "$(free_kb)" -ge "$minimum_free_kb" ] || exit 1

work=
committed=no
restore_failed=no
backed_up=
replaced=

restore_one() {
    # $1 = file name
    restore_tmp=$(mktemp "$dir/.restore.XXXXXX") || return 1
    if cp "$dir/$1.before-remote" "$restore_tmp" && chmod "$(mode_of "$1")" "$restore_tmp" && mv "$restore_tmp" "$dir/$1"; then
        return 0
    fi
    rm -f "$restore_tmp"
    return 1
}

cleanup() {
    result=$?
    set +e
    if [ "$committed" = no ]; then
        for name in $replaced; do
            if ! restore_one "$name"; then
                restore_failed=yes
                echo "ROLLBACK_FAILED: restore $name from $name.before-remote" >&2
            fi
        done
        # A backup is the only copy of the old file if its restore failed: keep all of them for a manual restore.
        if [ "$restore_failed" = no ]; then
            for name in $backed_up; do
                rm -f "$dir/$name.before-remote"
            done
        fi
    fi
    [ -z "$work" ] || rm -rf "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

work=$(mktemp -d "$dir/.remote-install.XXXXXX")
for name in $stage_files; do
    cp "$stage/$name" "$work/$name"
    cmp -s "$stage/$name" "$work/$name"
    chmod "$(mode_of "$name")" "$work/$name"
done

for name in $stage_files; do
    cp "$dir/$name" "$dir/$name.before-remote"
    backed_up="$backed_up $name"
    cmp -s "$dir/$name" "$dir/$name.before-remote"
    chmod 600 "$dir/$name.before-remote"
done

for name in $stage_files; do
    mv "$work/$name" "$dir/$name"
    replaced="$replaced $name"
done

for name in $stage_files; do
    cmp -s "$stage/$name" "$dir/$name"
    [ "$(digest "$dir/$name.before-remote")" = "$(pin_of "$name")" ]
done
sync
committed=yes
echo REMOTE_WAKE_INSTALLED
