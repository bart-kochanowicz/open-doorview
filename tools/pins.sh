# Source pins used by the build scripts. Sourced by other scripts; not meant to be run.
#
# The kernel tree and the config below are the ones the shipped modules were built against. The kernel is
# the OpenIPC fork of Linux 4.9.37 for Goke SoCs; the modules have no symbol versioning (CONFIG_MODVERSIONS
# is off), so they load on a kernel with the same vermagic: "4.9.37 mod_unload ARMv7 p2v8".

LINUX_REPO=https://github.com/OpenIPC/linux.git
LINUX_COMMIT=3b385fd89a375757b12660a0d7c8eb7b4f92c7a6

FIRMWARE_REPO=https://github.com/OpenIPC/firmware.git
FIRMWARE_COMMIT=03d11259e36294f8909d65e21c57e444859d19ce
KERNEL_CONFIG_PATH=br-ext-chip-goke/board/gk7205v200/gk7202v300.generic.config

# The sources of the earlier stage binaries (each installer pins the file it replaces, and EXPECTED-BUILDS.txt lists
# them). They are not kept as copies in the tree: tools/build.sh takes them from this commit, where every one of them
# still is, and builds them next to the current sources. A shallow clone needs "git fetch --unshallow" first.
OLD_SOURCES_COMMIT=ad57592a98f8254f42ec74dee61a7e99d5f03619
OLD_KERNEL_SOURCES='syslink-poll-stage1 syslink-net-irq-stage2 syslink-net-irq-stage3 syslink-net-irq-stage4 syslink-net-irq-stage6'
OLD_MQTT_SOURCES='mqtt-stage3 mqtt-stage5 mqtt-stage6 mqtt-stage7 mqtt-stage10 mqtt-stage12'

# Vendor LCD headers (public API of the SDK libraries that majestic also uses).
HISILICON_REPO=https://github.com/OpenIPC/openhisilicon.git
HISILICON_COMMIT=443c5d5b1bcd5998f01c92871129e2125948685a

# Vendor video-output kernel module: a proprietary binary, so it is downloaded, never stored in this repository.
VO_MODULE_PATH=general/package/goke-osdrv-gk7205v200/files/kmod/gk7205v200_vo.ko
VO_MODULE_SHA256=0ce191cd9c5663dbf26e0c170429e9c2efcbd282cea51e5c103fcb871bc95447

# The OpenIPC image the camera runs (informational; the build does not need it except for the LCD libraries).
OPENIPC_IMAGE_URL='https://openipc.org/cameras/vendors/goke/socs/gk7202v300/download_full_image?flash_size=8&flash_type=nor&fw_release=lite'
