#!/bin/sh
# Downloads the vendor video-output module the LCD stage needs and checks it against the pinned hash.
# The module is proprietary (it is part of the OpenIPC firmware repository), so it is not stored here.
# Usage: tools/fetch-vendor.sh      -> vendor/vo.ko
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
. "$here/pins.sh"

out=$repo/vendor/vo.ko
mkdir -p "$repo/vendor"
raw=https://raw.githubusercontent.com/OpenIPC/firmware/$FIRMWARE_COMMIT/$VO_MODULE_PATH

digest() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

if [ -f "$out" ] && [ "$(digest "$out")" = "$VO_MODULE_SHA256" ]; then
    echo "vendor/vo.ko already present and verified"
    exit 0
fi

tmp=$(mktemp "$repo/vendor/.vo.XXXXXX")
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$raw" -o "$tmp"
[ "$(digest "$tmp")" = "$VO_MODULE_SHA256" ] || { echo "vo.ko does not match the pinned SHA-256; refusing to use it" >&2; exit 1; }
mv "$tmp" "$out"
trap - EXIT
echo "vendor/vo.ko downloaded and verified"
