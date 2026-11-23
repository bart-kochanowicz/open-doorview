#!/bin/sh
# Extracts the libraries that vo-live-30 and first-snap link against (libc.so and the vendor libraries) from an
# OpenIPC full flash image, into build/rootfs-libs/. Needs Docker (the build image carries unsquashfs).
# Usage: tools/extract-rootfs-libs.sh <openipc-full-image.bin>
#
# The root filesystem of the 8 MB NOR image starts at flash offset 0x230000 (the boot log says
# "Found RootFS at 0x00230000").
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
image=${1:?usage: $0 <openipc-full-image.bin>}
[ -f "$image" ] || { echo "no such file: $image" >&2; exit 1; }
image=$(cd "$(dirname "$image")" && pwd)/$(basename "$image")

docker build -q -t open-doorview-build "$here/build" > /dev/null
mkdir -p "$repo/build/rootfs-libs"
docker run --rm -v "$repo":/repo -v "$image":/image.bin:ro -w /repo open-doorview-build sh -ec '
    dd if=/image.bin of=/tmp/rootfs.squashfs bs=4096 skip=$((0x230000 / 4096)) 2> /dev/null
    [ "$(head -c 4 /tmp/rootfs.squashfs)" = hsqs ] || { echo "no SquashFS at 0x230000: is this an 8 MB OpenIPC NOR image?" >&2; exit 1; }
    rm -rf /tmp/rootfs
    libs="libgk_api.so libgk_ae.so libgk_awb.so libgk_isp.so libupvqe.so libdnvqe.so libvoice_engine.so libldci.so libdehaze.so libdrc.so libir_auto.so libsecurec.so"
    unsquashfs -no-xattrs -d /tmp/rootfs /tmp/rootfs.squashfs lib/libc.so $(for l in $libs; do printf "usr/lib/%s " "$l"; done) > /dev/null
    cp /tmp/rootfs/lib/libc.so build/rootfs-libs/
    for l in $libs; do cp "/tmp/rootfs/usr/lib/$l" build/rootfs-libs/; done
    sha256sum build/rootfs-libs/*
'
