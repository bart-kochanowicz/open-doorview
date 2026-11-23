#!/bin/sh
# Runs inside the build container (see tools/build.sh).
set -eu

repo=/repo
. "$repo/tools/pins.sh"
src=$repo/build/src
out=$repo/build/out
mkdir -p "$src" "$out/kernel" "$out/userland"
cross=arm-linux-gnueabi-

fetch() { # <name> <repo-url> <commit> [git fetch options]
    name=$1; url=$2; commit=$3; shift 3
    if [ -d "$src/$name/.git" ] && [ "$(git -C "$src/$name" rev-parse HEAD 2> /dev/null)" = "$commit" ]; then
        echo "source $name already at $commit"
        return 0
    fi
    rm -rf "${src:?}/$name"
    mkdir -p "$src/$name"
    git -C "$src/$name" init -q
    git -C "$src/$name" remote add origin "$url"
    git -C "$src/$name" fetch -q --depth 1 "$@" origin "$commit"
    git -C "$src/$name" checkout -q FETCH_HEAD
}

echo "== kernel source (OpenIPC/linux $LINUX_COMMIT) =="
fetch linux "$LINUX_REPO" "$LINUX_COMMIT"
curl -fsSL "https://raw.githubusercontent.com/OpenIPC/firmware/$FIRMWARE_COMMIT/$KERNEL_CONFIG_PATH" -o "$src/linux/.config"
make -C "$src/linux" ARCH=arm CROSS_COMPILE=$cross olddefconfig > /dev/null
make -C "$src/linux" ARCH=arm CROSS_COMPILE=$cross modules_prepare > /dev/null
echo "kernel release: $(cat "$src/linux/include/config/kernel.release")"

build_module() { # <source dir under firmware/kernel> <module name> <output name>
    dir=$1; module=$2; name=$3
    work=$repo/build/modules/$dir
    rm -rf "$work"
    mkdir -p "$work"
    cp "$repo/firmware/kernel/$dir/"* "$work/"
    make -C "$src/linux" ARCH=arm CROSS_COMPILE=$cross M="$work" modules > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
    cp "$work/$module.ko" "$out/kernel/$name"
}
echo "== kernel modules =="
build_module syslink-poll-stage1 syslink_poll syslink_poll-stage1.ko
build_module syslink-handshake syslink_poll syslink_poll.ko
build_module syslink-handshake syslink_bg syslink_bg.ko
build_module syslink-net-poll syslink_net syslink_net.ko
build_module syslink-net-irq-stage2 syslink_net syslink_net_irq-stage2.ko
build_module syslink-net-irq-stage3 syslink_net syslink_net_irq-stage3.ko
build_module syslink-net-irq syslink_net syslink_net_irq.ko

echo "== camera binaries =="
mqtt=$repo/firmware/userland/mqtt
${cross}gcc -Os -mfloat-abi=soft -march=armv7-a -Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-stack-protector \
    -nostdlib -static -Wl,--gc-sections -Wl,--build-id -o "$out/userland/doorview-mqtt" "$mqtt/doorview-mqtt.c" "$mqtt/sys-arm.c"
${cross}strip "$out/userland/doorview-mqtt"

lcd=$repo/firmware/userland/lcd
${cross}gcc -Os -mfloat-abi=soft -march=armv7-a -ffreestanding -fno-stack-protector -nostdlib -static -Wl,--build-id \
    -o "$out/userland/button-preview" "$lcd/button-preview.c"
${cross}strip "$out/userland/button-preview"

if [ -f "$repo/build/rootfs-libs/libgk_api.so" ] && [ -f "$repo/build/rootfs-libs/libc.so" ]; then
    echo "== vendor headers (OpenIPC/openhisilicon $HISILICON_COMMIT) =="
    if [ ! -f "$src/openhisilicon/include/gk_api_vo.h" ]; then
        rm -rf "${src:?}/openhisilicon"
        mkdir -p "$src/openhisilicon"
        git -C "$src/openhisilicon" init -q
        git -C "$src/openhisilicon" remote add origin "$HISILICON_REPO"
        git -C "$src/openhisilicon" config core.sparseCheckout true
        printf 'include\n' > "$src/openhisilicon/.git/info/sparse-checkout"
        git -C "$src/openhisilicon" fetch -q --depth 1 --filter=blob:none origin "$HISILICON_COMMIT"
        git -C "$src/openhisilicon" checkout -q FETCH_HEAD
    fi
    ${cross}gcc -Os -mfloat-abi=soft -march=armv7-a -ffreestanding -fno-stack-protector -nostdlib \
        -I"$src/openhisilicon/include" -Wl,--allow-shlib-undefined -Wl,--dynamic-linker=/lib/ld-musl-arm.so.1 -Wl,--build-id \
        -o "$out/userland/vo-live-30" "$lcd/vo-live-30.c" -L"$repo/build/rootfs-libs" -l:libgk_api.so -l:libc.so
    ${cross}strip "$out/userland/vo-live-30"
else
    echo "vo-live-30 skipped: pass --rootfs-libs DIR (libc.so and libgk_api.so from the OpenIPC root filesystem)"
fi

echo "== comparison with the binaries tested on a camera =="
status=0
while read -r expected name kind; do
    case "$expected" in ''|'#'*) continue ;; esac
    case "$name" in
        syslink_*) file=$out/kernel/$name ;;
        *) file=$out/userland/$name ;;
    esac
    if [ ! -f "$file" ]; then
        printf '%-28s %s\n' "$name" "not built"
        continue
    fi
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$actual" = "$expected" ]; then
        printf '%-28s %s\n' "$name" "identical to the tested binary"
    else
        printf '%-28s %s\n' "$name" "differs from the tested binary ($kind)"
        [ "$kind" = reproducible ] && status=1
    fi
done < "$repo/firmware/EXPECTED-BUILDS.txt"
exit "$status"
