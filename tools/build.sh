#!/bin/sh
# Builds the kernel modules and camera binaries in a Docker container and compares them with the hashes of the
# binaries that were tested on a camera. Needs Docker and network access (it downloads the pinned kernel source).
# Usage: tools/build.sh [--rootfs-libs DIR]
#   --rootfs-libs DIR   a directory holding libc.so and libgk_api.so from the OpenIPC root filesystem; only
#                       needed to rebuild vo-live-30. tools/extract-rootfs-libs.sh fills build/rootfs-libs,
#                       which is used automatically.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")

libs=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rootfs-libs) libs=$2; shift 2 ;;
        *) echo "usage: $0 [--rootfs-libs DIR]" >&2; exit 2 ;;
    esac
done

docker build -q -t open-doorview-build "$here/build" > /dev/null
mkdir -p "$repo/build/rootfs-libs"
if [ -n "$libs" ] && [ "$(cd "$libs" && pwd)" != "$repo/build/rootfs-libs" ]; then
    cp "$libs/libc.so" "$libs/libgk_api.so" "$repo/build/rootfs-libs/"
fi
docker run --rm -v "$repo":/repo -w /repo open-doorview-build sh tools/build-in-container.sh
