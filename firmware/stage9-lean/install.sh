#!/bin/sh
set -eu

# Makes the start leaner: /etc/init.d/rcS (the stage 8 script without zram swap and the SSH server) and
# /usr/bin/load_goke (the stock vendor loader without the six audio modules; Majestic runs with audio off). The old
# files are kept in /etc/doorview as <name>.before-lean for rollback.sh. They are not kept next to the originals:
# the stock rcS runs every S??* script in /etc/init.d.
stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-60}

backup_dir=$root/etc/doorview
init_dir=$root/etc/init.d
bin_dir=$root/usr/bin

stage_files='rcS load_goke'

# The exact files this update replaces: the stage 8 rcS and the stock vendor loader.
pin_of() {
    case "$1" in
        rcS) echo af51c77618b88af88bcd010462226ce51ef300f1b3327715c8b7d0cd7d7c1233 ;;
        load_goke) echo 768fd7a612188be71f0ef9b8ceebc7e9e758331ed24ab0f2b8ab6b59914d24e9 ;;
    esac
}

dir_of() {
    case "$1" in
        rcS) echo "$init_dir" ;;
        load_goke) echo "$bin_dir" ;;
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
    $2 == "/etc" || $2 == "/etc/doorview" || $2 == "/etc/init.d" || $2 == "/usr" || $2 == "/usr/bin" { masked = 1 }
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
    absent "$backup_dir/$name.before-lean" || exit 1
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
    if cp "$backup_dir/$1.before-lean" "$restore_tmp" && chmod 755 "$restore_tmp" && mv "$restore_tmp" "$(dir_of "$1")/$1"; then
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
                echo "ROLLBACK_FAILED: restore $name from $name.before-lean" >&2
            fi
        done
        # A backup is the only copy of the old script if its restore failed: keep all of them for a manual restore.
        if [ "$restore_failed" = no ]; then
            for name in $backed_up; do
                rm -f "$backup_dir/$name.before-lean"
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
work=$(mktemp -d "$init_dir/.lean-install.XXXXXX")
work_bin=$(mktemp -d "$bin_dir/.lean-install.XXXXXX")
for name in $stage_files; do
    case "$name" in rcS) w=$work ;; *) w=$work_bin ;; esac
    cp "$stage/$name" "$w/$name"
    cmp -s "$stage/$name" "$w/$name"
    chmod 755 "$w/$name"
done

# Keep the running files in /etc/doorview so that they can be restored.
for name in $stage_files; do
    cp "$(dir_of "$name")/$name" "$backup_dir/$name.before-lean"
    backed_up="$backed_up $name"
    cmp -s "$(dir_of "$name")/$name" "$backup_dir/$name.before-lean"
    chmod 600 "$backup_dir/$name.before-lean"
done

for name in $stage_files; do
    case "$name" in rcS) w=$work ;; *) w=$work_bin ;; esac
    mv "$w/$name" "$(dir_of "$name")/$name"
    replaced="$replaced $name"
done

for name in $stage_files; do
    cmp -s "$stage/$name" "$(dir_of "$name")/$name"
    [ "$(digest "$backup_dir/$name.before-lean")" = "$(pin_of "$name")" ]
done
sync
committed=yes
echo LEAN_INSTALLED
