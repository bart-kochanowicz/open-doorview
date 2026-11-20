#!/bin/sh
set -eu

# Installs the Wi-Fi base on a fresh OpenIPC overlay: the SDIO handshake (S39), the three SDIO modules and the
# Wi-Fi startup script (S41). Credentials are NOT part of this step; install them afterwards with configure.sh.
# Usage: install.sh <directory with the staged files and SHA256SUMS>

stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-100}

module_dir=$root/etc/doorview
init_dir=$root/etc/init.d

module_files='syslink_poll.ko syslink_bg.ko syslink_net.ko'
hook_files='S39doorview S41doorview-network'
stage_files="$module_files $hook_files"

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

# The writable overlay must be the jffs2 partition mounted at /overlay, and nothing may mask the target directories.
awk '
    $2 == "/" && $3 == "overlay" { root_overlay = 1 }
    $1 == "/dev/mtdblock5" && $2 == "/overlay" && $3 == "jffs2" { data = 1 }
    $2 == "/etc" || $2 == "/etc/doorview" || $2 == "/etc/init.d" { masked = 1 }
    END { exit !(root_overlay && data && !masked) }
' "$mounts"

[ -d "$init_dir" ] && [ ! -L "$init_dir" ] || exit 1
absent "$module_dir" || { [ -d "$module_dir" ] && [ ! -L "$module_dir" ]; } || exit 1
for name in $stage_files; do
    [ -f "$stage/$name" ] && [ ! -L "$stage/$name" ] || exit 1
done
[ -f "$stage/SHA256SUMS" ] || exit 1
while read -r sum name; do
    [ "$(digest "$stage/$name")" = "$sum" ] || exit 1
done < "$stage/SHA256SUMS"
for name in $stage_files; do
    grep -q " $name\$" "$stage/SHA256SUMS" || exit 1
done

# Never overwrite anything that already exists.
for name in $module_files; do
    absent "$module_dir/$name" || exit 1
done
for name in $hook_files; do
    absent "$init_dir/$name" || exit 1
done
[ "$(free_kb)" -ge "$minimum_free_kb" ] || exit 1

created_dir=no
placed=
tmp_dir=
committed=no

cleanup() {
    result=$?
    set +e
    [ -z "$tmp_dir" ] || rm -rf "$tmp_dir"
    if [ "$committed" = no ]; then
        for path in $placed; do
            rm -f "$path"
        done
        [ "$created_dir" = no ] || rmdir "$module_dir" 2> /dev/null
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ ! -d "$module_dir" ]; then
    mkdir "$module_dir"
    chmod 700 "$module_dir"
    created_dir=yes
fi
tmp_dir=$(mktemp -d "$module_dir/.wifi-install.XXXXXX")

# Copy and verify everything first, then move into place. The boot hooks go last so a hook never appears
# before the modules it needs.
for name in $module_files; do
    cp "$stage/$name" "$tmp_dir/$name"
    cmp -s "$stage/$name" "$tmp_dir/$name"
    chmod 600 "$tmp_dir/$name"
done
for name in $hook_files; do
    cp "$stage/$name" "$tmp_dir/$name"
    cmp -s "$stage/$name" "$tmp_dir/$name"
    chmod 755 "$tmp_dir/$name"
done

for name in $module_files; do
    mv "$tmp_dir/$name" "$module_dir/$name"
    placed="$placed $module_dir/$name"
done
for name in $hook_files; do
    mv "$tmp_dir/$name" "$init_dir/$name"
    placed="$placed $init_dir/$name"
done

for name in $module_files; do
    cmp -s "$stage/$name" "$module_dir/$name"
done
for name in $hook_files; do
    cmp -s "$stage/$name" "$init_dir/$name"
done
sync
committed=yes
echo WIFI_BASE_INSTALLED
