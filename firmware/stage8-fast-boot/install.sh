#!/bin/sh
set -eu

# Replaces three start-up scripts so that the camera is ready sooner after a wake-up: /etc/init.d/rcS (skips the
# services the camera does not use and starts the Wi-Fi link and the camera stack side by side), S39doorview and
# S41doorview-network (they poll instead of sleeping a fixed second). The old scripts are kept in /etc/doorview as
# <name>.before-fast for rollback.sh. They are not kept in /etc/init.d: the stock rcS would run a copy there.
stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-60}

backup_dir=$root/etc/doorview
init_dir=$root/etc/init.d

stage_files='rcS S39doorview S41doorview-network'

# The exact scripts this update replaces: the stock rcS, and the stage 1 and stage 2 scripts.
pin_of() {
    case "$1" in
        rcS) echo 1ca35513c874f3e89ad790b7841c07db9eef6be7c1f0469596de82b4fa87fe67 ;;
        S39doorview) echo 80a2f3c38d644e8eda39a66420c70d1ced33e33ea70fa4be17a278db2e347042 ;;
        S41doorview-network) echo ee6356aff3610c3f8dbcc7facc7894dd10bb3fca082d1954d49616d99c2b44f1 ;;
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
    $2 == "/etc" || $2 == "/etc/doorview" || $2 == "/etc/init.d" { masked = 1 }
    END { exit !(root_overlay && data && !masked) }
' "$mounts"

[ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || exit 1
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

# Update only the exact scripts that were tested, and never overwrite other state.
for name in $stage_files; do
    [ -f "$init_dir/$name" ] && [ ! -L "$init_dir/$name" ] && [ "$(digest "$init_dir/$name")" = "$(pin_of "$name")" ] || exit 1
    absent "$backup_dir/$name.before-fast" || exit 1
done
[ "$(free_kb)" -ge "$minimum_free_kb" ] || exit 1

work=
committed=no
restore_failed=no
backed_up=
replaced=

restore_one() {
    # $1 = script name
    restore_tmp=$(mktemp "$init_dir/.restore.XXXXXX") || return 1
    if cp "$backup_dir/$1.before-fast" "$restore_tmp" && chmod 755 "$restore_tmp" && mv "$restore_tmp" "$init_dir/$1"; then
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
                echo "ROLLBACK_FAILED: restore $name from $name.before-fast" >&2
            fi
        done
        # A backup is the only copy of the old script if its restore failed: keep all of them for a manual restore.
        if [ "$restore_failed" = no ]; then
            for name in $backed_up; do
                rm -f "$backup_dir/$name.before-fast"
            done
        fi
    fi
    [ -z "$work" ] || rm -rf "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

work=$(mktemp -d "$init_dir/.fast-install.XXXXXX")
for name in $stage_files; do
    cp "$stage/$name" "$work/$name"
    cmp -s "$stage/$name" "$work/$name"
    chmod 755 "$work/$name"
done

# Keep the running scripts outside /etc/init.d so that they can be restored.
for name in $stage_files; do
    cp "$init_dir/$name" "$backup_dir/$name.before-fast"
    backed_up="$backed_up $name"
    cmp -s "$init_dir/$name" "$backup_dir/$name.before-fast"
    chmod 600 "$backup_dir/$name.before-fast"
done

for name in $stage_files; do
    mv "$work/$name" "$init_dir/$name"
    replaced="$replaced $name"
done

for name in $stage_files; do
    cmp -s "$stage/$name" "$init_dir/$name"
    [ "$(digest "$backup_dir/$name.before-fast")" = "$(pin_of "$name")" ]
done
sync
committed=yes
echo FAST_BOOT_INSTALLED
