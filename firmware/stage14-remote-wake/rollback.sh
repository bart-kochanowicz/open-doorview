#!/bin/sh
set -eu

# Puts back the daemon and the driver that were installed before install.sh. The wake_* lines in mqtt.conf may stay:
# the old daemon ignores keys it does not know.
root=${DOORVIEW_ROOT:-}
dir=$root/etc/doorview

stage_files='doorview-mqtt syslink_net_irq.ko'

pin_of() {
    case "$1" in
        doorview-mqtt) echo f376c655eebf9ab7c2fd8ef76d4bbbba298b03b5528134397f9a72335cef2b79 ;;
        syslink_net_irq.ko) echo fbdc6b89903c433641b5b87e89af38a13a3b540264eb07a5bf25d29f1c2565e0 ;;
    esac
}

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

[ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
for name in $stage_files; do
    [ -f "$dir/$name.before-remote" ] && [ "$(digest "$dir/$name.before-remote")" = "$(pin_of "$name")" ] || exit 1
done

tmps=
trap 'for t in $tmps; do rm -f "$t"; done' EXIT
for name in $stage_files; do
    tmp=$(mktemp "$dir/.restore.XXXXXX")
    tmps="$tmps $tmp"
    cp "$dir/$name.before-remote" "$tmp"
    cmp -s "$dir/$name.before-remote" "$tmp"
    chmod "$(mode_of "$name")" "$tmp"
done

set -- $tmps
for name in $stage_files; do
    mv "$1" "$dir/$name"
    shift
done
tmps=
for name in $stage_files; do
    [ "$(digest "$dir/$name")" = "$(pin_of "$name")" ]
    rm -f "$dir/$name.before-remote"
done
sync
echo REMOTE_WAKE_ROLLED_BACK
