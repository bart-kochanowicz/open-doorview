#!/bin/sh
# Assembles an installable package for one stage: a flat directory with the installer, the payload files and
# SHA256SUMS, plus a .tar.gz of it that tools/upload-archive.py can send to the camera.
#
# Usage: tools/package.sh stage1-wifi | stage2-lcd | stage3-mqtt | stage4-sleep | stage5-sleep-daemon | stage6-wake-timer | stage7-pir-motion | stage8-fast-boot | stage9-lean | stage10-early-daemon
# Output: build/packages/<stage>/  and  build/packages/<stage>.tar.gz
#
# stage2-lcd needs the vendor video-output module: run tools/fetch-vendor.sh first.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
stage_name=${1:-}

digest() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

case "$stage_name" in
    stage1-wifi)
        payload='etc/doorview/syslink_poll.ko etc/doorview/syslink_bg.ko etc/doorview/syslink_net.ko etc/init.d/S39doorview etc/init.d/S41doorview-network'
        scripts='install.sh rollback.sh configure.sh'
        ;;
    stage2-lcd)
        payload='etc/init.d/S41doorview-network etc/init.d/S96doorview-lcd etc/doorview/syslink_net_irq.ko etc/doorview-lcd/service etc/doorview-lcd/libuclibc-compat.so etc/doorview-lcd/vo-live-30 etc/doorview-lcd/button-preview etc/doorview-lcd/live-30.sh'
        scripts='install.sh rollback.sh'
        ;;
    stage3-mqtt)
        payload='etc/doorview/syslink_net_irq.ko etc/doorview/doorview-mqtt etc/init.d/S97doorview-mqtt'
        scripts='install.sh rollback.sh configure.sh'
        ;;
    stage4-sleep)
        payload='etc/doorview/syslink_poll.ko etc/doorview/syslink_net_irq.ko'
        scripts='install.sh rollback.sh'
        ;;
    stage5-sleep-daemon)
        payload='etc/doorview/doorview-mqtt'
        scripts='install.sh rollback.sh'
        ;;
    stage6-wake-timer)
        payload='etc/doorview/doorview-mqtt etc/doorview/syslink_net_irq.ko'
        scripts='install.sh rollback.sh'
        ;;
    stage7-pir-motion)
        payload='etc/doorview/doorview-mqtt'
        scripts='install.sh rollback.sh'
        ;;
    stage8-fast-boot)
        payload='etc/init.d/rcS etc/init.d/S39doorview etc/init.d/S41doorview-network'
        scripts='install.sh rollback.sh'
        ;;
    stage9-lean)
        payload='etc/init.d/rcS usr/bin/load_goke'
        scripts='install.sh rollback.sh'
        ;;
    stage10-early-daemon)
        payload='etc/init.d/rcS etc/doorview/doorview-mqtt'
        scripts='install.sh rollback.sh'
        ;;
    *)
        echo "usage: $0 stage1-wifi | stage2-lcd | stage3-mqtt | stage4-sleep | stage5-sleep-daemon | stage6-wake-timer | stage7-pir-motion | stage8-fast-boot | stage9-lean | stage10-early-daemon" >&2
        exit 2
        ;;
esac

source_dir=$repo/firmware/$stage_name
out_root=$repo/build/packages
target=$out_root/$stage_name
rm -rf "$target" "$out_root/$stage_name.tar.gz"
mkdir -p "$target"

: > "$target/SHA256SUMS"
for path in $payload; do
    cp "$source_dir/payload/$path" "$target/$(basename "$path")"
    printf '%s  %s\n' "$(digest "$target/$(basename "$path")")" "$(basename "$path")" >> "$target/SHA256SUMS"
done
if [ "$stage_name" = stage2-lcd ]; then
    vendor=$repo/vendor/vo.ko
    [ -f "$vendor" ] || { echo "vendor/vo.ko is missing: run tools/fetch-vendor.sh first" >&2; exit 1; }
    . "$here/pins.sh"
    [ "$(digest "$vendor")" = "$VO_MODULE_SHA256" ] || { echo "vendor/vo.ko does not match the pinned hash" >&2; exit 1; }
    cp "$vendor" "$target/vo.ko"
    printf '%s  %s\n' "$VO_MODULE_SHA256" vo.ko >> "$target/SHA256SUMS"
fi
for script in $scripts; do
    cp "$source_dir/$script" "$target/$script"
done

COPYFILE_DISABLE=1 tar -czf "$out_root/$stage_name.tar.gz" -C "$target" .
echo "package:  $target"
echo "archive:  $out_root/$stage_name.tar.gz"
echo "sha256:   $(digest "$out_root/$stage_name.tar.gz")"
