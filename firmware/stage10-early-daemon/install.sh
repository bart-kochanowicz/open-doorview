#!/bin/sh
set -eu

# Starts the MQTT daemon right after the Wi-Fi link instead of after Majestic: /etc/init.d/rcS (the stage 9 script
# with the daemon moved up and only the loopback of the stock network start) and /etc/doorview/doorview-mqtt (the
# build that retries the first picture while Majestic starts and sets the PIR up after it). The old files are kept in
# /etc/doorview as <name>.before-early for rollback.sh.
stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-60}

backup_dir=$root/etc/doorview
init_dir=$root/etc/init.d
bin_dir=$root/etc/doorview

stage_files='rcS doorview-mqtt'

# The exact files this update replaces: the stage 9 rcS and the stage 7 daemon.
pin_of() {
    case "$1" in
        rcS) echo e98571c2b915ecafa5f7bc89e2cd1c99607b0d0c6de2dbd818a53fac7cb4987f ;;
        doorview-mqtt) echo b27eb7bc81d94ab4bcbd9b2321eb84c4a8ae07c115c8f0bedd446da5dc278d26 ;;
    esac
}

dir_of() {
    case "$1" in
        rcS) echo "$init_dir" ;;
        doorview-mqtt) echo "$bin_dir" ;;
    esac
}

# The boot script must be executable by everyone; the daemon only by its owner, as stage 3 installed it.
mode_of() {
    case "$1" in
        rcS) echo 755 ;;
        doorview-mqtt) echo 700 ;;
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
[ -d "$bin_dir" ] && [ ! -L "$bin_dir" ] || exit 1
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
    target=$(dir_of "$name")/$name
    [ -f "$target" ] && [ ! -L "$target" ] && [ "$(digest "$target")" = "$(pin_of "$name")" ] || exit 1
    absent "$backup_dir/$name.before-early" || exit 1
done
[ "$(free_kb)" -ge "$minimum_free_kb" ] || exit 1

work=
work_bin=
committed=no
restore_failed=no
backed_up=
replaced=

restore_one() {
    # $1 = script name
    restore_tmp=$(mktemp "$(dir_of "$1")/.restore.XXXXXX") || return 1
    if cp "$backup_dir/$1.before-early" "$restore_tmp" && chmod "$(mode_of "$1")" "$restore_tmp" && mv "$restore_tmp" "$(dir_of "$1")/$1"; then
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
                echo "ROLLBACK_FAILED: restore $name from $name.before-early" >&2
            fi
        done
        # A backup is the only copy of the old script if its restore failed: keep all of them for a manual restore.
        if [ "$restore_failed" = no ]; then
            for name in $backed_up; do
                rm -f "$backup_dir/$name.before-early"
            done
        fi
    fi
    [ -z "$work" ] || rm -rf "$work"
    [ -z "$work_bin" ] || rm -rf "$work_bin"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# One staging directory per target directory, so that the final rename never crosses a file system.
work=$(mktemp -d "$init_dir/.early-install.XXXXXX")
work_bin=$(mktemp -d "$bin_dir/.early-install.XXXXXX")
for name in $stage_files; do
    case "$name" in rcS) w=$work ;; *) w=$work_bin ;; esac
    cp "$stage/$name" "$w/$name"
    cmp -s "$stage/$name" "$w/$name"
    chmod "$(mode_of "$name")" "$w/$name"
done

# Keep the running files in /etc/doorview so that they can be restored.
for name in $stage_files; do
    cp "$(dir_of "$name")/$name" "$backup_dir/$name.before-early"
    backed_up="$backed_up $name"
    cmp -s "$(dir_of "$name")/$name" "$backup_dir/$name.before-early"
    chmod 600 "$backup_dir/$name.before-early"
done

for name in $stage_files; do
    case "$name" in rcS) w=$work ;; *) w=$work_bin ;; esac
    mv "$w/$name" "$(dir_of "$name")/$name"
    replaced="$replaced $name"
done

for name in $stage_files; do
    cmp -s "$stage/$name" "$(dir_of "$name")/$name"
    [ "$(digest "$backup_dir/$name.before-early")" = "$(pin_of "$name")" ]
done
sync
committed=yes
echo EARLY_DAEMON_INSTALLED
