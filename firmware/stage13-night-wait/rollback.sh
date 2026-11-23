#!/bin/sh
set -eu

# Puts back the daemon that was installed before install.sh. night_wait_ms can stay in mqtt.conf: the old daemon
# ignores keys it does not know.
root=${DOORVIEW_ROOT:-}
dir=$root/etc/doorview

stage_files='doorview-mqtt'

pin_of() {
    case "$1" in
        doorview-mqtt) echo 8332cad1353630d9b0c898e406a4feab061b31a35a34b62ce249d9679bec50cc ;;
    esac
}

mode_of() {
    case "$1" in
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

[ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
for name in $stage_files; do
    [ -f "$dir/$name.before-night" ] && [ "$(digest "$dir/$name.before-night")" = "$(pin_of "$name")" ] || exit 1
done

tmps=
trap 'for t in $tmps; do rm -f "$t"; done' EXIT
for name in $stage_files; do
    tmp=$(mktemp "$dir/.restore.XXXXXX")
    tmps="$tmps $tmp"
    cp "$dir/$name.before-night" "$tmp"
    cmp -s "$dir/$name.before-night" "$tmp"
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
    rm -f "$dir/$name.before-night"
done
sync
echo NIGHT_WAIT_ROLLED_BACK
