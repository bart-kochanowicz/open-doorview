#!/bin/sh
set -eu

# Puts back the rcS and the daemon that were installed before install.sh. The rcS is written back as a file (not
# deleted): removing it would make the overlay hide the stock file of the read-only root file system.
root=${DOORVIEW_ROOT:-}
backup_dir=$root/etc/doorview
init_dir=$root/etc/init.d
bin_dir=$root/etc/doorview

stage_files='rcS doorview-mqtt'

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

[ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || exit 1
[ -d "$init_dir" ] && [ ! -L "$init_dir" ] || exit 1
[ -d "$bin_dir" ] && [ ! -L "$bin_dir" ] || exit 1
for name in $stage_files; do
    [ -f "$backup_dir/$name.before-early" ] && [ "$(digest "$backup_dir/$name.before-early")" = "$(pin_of "$name")" ] || exit 1
done

tmps=
trap 'for t in $tmps; do rm -f "$t"; done' EXIT
for name in $stage_files; do
    tmp=$(mktemp "$(dir_of "$name")/.restore.XXXXXX")
    tmps="$tmps $tmp"
    cp "$backup_dir/$name.before-early" "$tmp"
    cmp -s "$backup_dir/$name.before-early" "$tmp"
    chmod "$(mode_of "$name")" "$tmp"
done

set -- $tmps
for name in $stage_files; do
    mv "$1" "$(dir_of "$name")/$name"
    shift
done
tmps=
for name in $stage_files; do
    [ "$(digest "$(dir_of "$name")/$name")" = "$(pin_of "$name")" ]
    rm -f "$backup_dir/$name.before-early"
done
sync
echo EARLY_DAEMON_ROLLED_BACK
