#!/bin/sh
set -eu

# Puts back the rcS and the vendor loader that were installed before install.sh. They are written back as files (not
# deleted): removing them would make the overlay hide the file of the read-only root file system.
root=${DOORVIEW_ROOT:-}
backup_dir=$root/etc/doorview
init_dir=$root/etc/init.d
bin_dir=$root/usr/bin

stage_files='rcS load_goke'

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

[ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || exit 1
[ -d "$init_dir" ] && [ ! -L "$init_dir" ] || exit 1
[ -d "$bin_dir" ] && [ ! -L "$bin_dir" ] || exit 1
for name in $stage_files; do
    [ -f "$backup_dir/$name.before-lean" ] && [ "$(digest "$backup_dir/$name.before-lean")" = "$(pin_of "$name")" ] || exit 1
done

tmps=
trap 'for t in $tmps; do rm -f "$t"; done' EXIT
for name in $stage_files; do
    tmp=$(mktemp "$(dir_of "$name")/.restore.XXXXXX")
    tmps="$tmps $tmp"
    cp "$backup_dir/$name.before-lean" "$tmp"
    cmp -s "$backup_dir/$name.before-lean" "$tmp"
    chmod 755 "$tmp"
done

set -- $tmps
for name in $stage_files; do
    mv "$1" "$(dir_of "$name")/$name"
    shift
done
tmps=
for name in $stage_files; do
    [ "$(digest "$(dir_of "$name")/$name")" = "$(pin_of "$name")" ]
    rm -f "$backup_dir/$name.before-lean"
done
sync
echo LEAN_ROLLED_BACK
