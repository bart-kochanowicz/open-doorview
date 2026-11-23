#!/bin/sh
set -eu

# Puts back the LCD boot hook that was installed before install.sh.
root=${DOORVIEW_ROOT:-}
backup_dir=$root/etc/doorview
init_dir=$root/etc/init.d

stage_files='S96doorview-lcd'

pin_of() {
    case "$1" in
        S96doorview-lcd) echo 5904afcc427617df4828f74058cc526922f9fc6527ef03806194028ede96e11f ;;
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
    [ -f "$backup_dir/$name.before-wake" ] && [ "$(digest "$backup_dir/$name.before-wake")" = "$(pin_of "$name")" ] || exit 1
done

tmps=
trap 'for t in $tmps; do rm -f "$t"; done' EXIT
for name in $stage_files; do
    tmp=$(mktemp "$init_dir/.restore.XXXXXX")
    tmps="$tmps $tmp"
    cp "$backup_dir/$name.before-wake" "$tmp"
    cmp -s "$backup_dir/$name.before-wake" "$tmp"
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
    rm -f "$backup_dir/$name.before-wake"
done
sync
echo WAKE_PREVIEW_ROLLED_BACK
