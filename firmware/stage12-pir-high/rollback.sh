#!/bin/sh
set -eu

# Puts back the daemon and the driver that were installed before install.sh. A pir_sensitivity above 3 in mqtt.conf
# must be lowered first: the old daemon refuses it and would not start.
root=${DOORVIEW_ROOT:-}
dir=$root/etc/doorview
config=$dir/mqtt.conf

stage_files='doorview-mqtt syslink_net_irq.ko'

pin_of() {
    case "$1" in
        doorview-mqtt) echo eebdb3b36b8532cbeeae2639069e83e1628b317aca1cfbbf80aea3a0762c7471 ;;
        syslink_net_irq.ko) echo 5a35ec4dd560094eaa55023ea49514b52c9e6d2364d50d485f035df0d504d2ec ;;
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
    [ -f "$dir/$name.before-high" ] && [ "$(digest "$dir/$name.before-high")" = "$(pin_of "$name")" ] || exit 1
done
if [ -f "$config" ] && grep -Eq '^pir_sensitivity=[45]' "$config"; then
    echo "lower pir_sensitivity in mqtt.conf to 3 or less first: the old daemon refuses it" >&2
    exit 1
fi

tmps=
trap 'for t in $tmps; do rm -f "$t"; done' EXIT
for name in $stage_files; do
    tmp=$(mktemp "$dir/.restore.XXXXXX")
    tmps="$tmps $tmp"
    cp "$dir/$name.before-high" "$tmp"
    cmp -s "$dir/$name.before-high" "$tmp"
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
    rm -f "$dir/$name.before-high"
done
sync
echo PIR_HIGH_ROLLED_BACK
