#!/bin/sh
set -eu

# Puts back the three start-up scripts that were installed before install.sh. The stock rcS is written back as a file
# (not deleted): removing it would make the overlay hide the file of the read-only root file system.
root=${DOORVIEW_ROOT:-}
backup_dir=$root/etc/doorview
init_dir=$root/etc/init.d

stage_files='rcS S39doorview S41doorview-network'

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

[ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || exit 1
[ -d "$init_dir" ] && [ ! -L "$init_dir" ] || exit 1
for name in $stage_files; do
    [ -f "$backup_dir/$name.before-fast" ] && [ "$(digest "$backup_dir/$name.before-fast")" = "$(pin_of "$name")" ] || exit 1
done

tmps=
trap 'for t in $tmps; do rm -f "$t"; done' EXIT
for name in $stage_files; do
    tmp=$(mktemp "$init_dir/.restore.XXXXXX")
    tmps="$tmps $tmp"
    cp "$backup_dir/$name.before-fast" "$tmp"
    cmp -s "$backup_dir/$name.before-fast" "$tmp"
    chmod 755 "$tmp"
done

set -- $tmps
for name in $stage_files; do
    mv "$1" "$init_dir/$name"
    shift
done
tmps=
for name in $stage_files; do
    [ "$(digest "$init_dir/$name")" = "$(pin_of "$name")" ]
    rm -f "$backup_dir/$name.before-fast"
done
sync
echo FAST_BOOT_ROLLED_BACK
