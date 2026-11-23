# Building and testing

The repository ships the exact binaries that were tested on a camera (in the `payload/` directory of each stage). You only need to build if you want to check them, change the source, or target a different kernel.

## What is built from what

| Output | Source | Toolchain | Reproduces the tested binary? |
|---|---|---|---|
| `syslink_poll.ko`, `syslink_net.ko` (stage 1), `syslink_net_irq.ko` (stages 2 and 3) | `firmware/kernel/` | Debian 12 `gcc-arm-linux-gnueabi` 12.2.0, OpenIPC Linux 4.9.37 tree | **Yes, bit for bit** (verified from a clean Docker image and a fresh shallow clone) |
| `doorview-mqtt` | `firmware/userland/mqtt/` | same compiler, freestanding, `-Os -mfloat-abi=soft -march=armv7-a` | **Yes, bit for bit** |
| `button-preview`, `vo-live-30` | `firmware/userland/lcd/` | same compiler | **No.** The tested binaries came from command lines that were not recorded. A rebuild is the same source but not identical, and has not been tried on a camera |
| `first-snap` (a measurement prototype, see [first-snap](first-snap.md)) | `firmware/userland/capture/` | same compiler, linked against the OpenIPC `libc.so` only | Not applicable: **never run on a camera**, no tested binary exists |
| `syslink_bg.ko` | `firmware/kernel/syslink-handshake/syslink_bg.c` | same | **No.** The shipped binary was built from an earlier revision of the source that was not kept; see [known limits](known-limits.md) |
| `libuclibc-compat.so` | OpenIPC `general/package/uclibc-compat` (MIT) | not rebuilt | Shipped as tested; a rebuild from the current upstream source gave a different file |
| `vo.ko` | OpenIPC `goke-osdrv-gk7205v200` (proprietary) | not built | Downloaded by `tools/fetch-vendor.sh`, hash-checked, never stored here |

`firmware/EXPECTED-BUILDS.txt` lists the hash of every tested binary and its status; `tools/build.sh` compares against it.

## Rebuilding

Needs Docker and network access. It builds a Debian 12 image, fetches the pinned kernel source (a shallow clone of one commit of `OpenIPC/linux`), takes the kernel configuration from OpenIPC's firmware repository, builds the modules out of tree, and compares hashes.

```sh
tools/build.sh
```

To also rebuild `vo-live-30` (and build `first-snap`) you need two libraries from the OpenIPC root file system. Extract them from the image you flashed:

```sh
tools/extract-rootfs-libs.sh openipc-gk7202v300-nor-lite-8mb.bin     # fills build/rootfs-libs/
tools/build.sh
```

Output goes to `build/out/{kernel,userland}/`. All pins (kernel commit, config path, headers commit, vendor module hash) are in `tools/pins.sh`.

If you use a different OpenIPC image than the one in [openipc-flash.md](openipc-flash.md), the kernel configuration may differ. The modules carry no symbol versioning, so a module only loads if the vermagic string is identical (`4.9.37 mod_unload ARMv7 p2v8`); check with `modinfo` on the camera, and compare the `.config` your image was built from with the one the script fetches.

### Using your own build

The installers check the hash of the files they replace. The chain is: stage 2 requires the exact stage 1 `S41doorview-network` and `syslink_net.ko`; stage 3 requires the exact stage 2 `syslink_net_irq.ko`. All of these reproduce bit for bit, so a rebuild fits. If you change source, you change a hash and the next stage's installer will refuse: edit the pinned hashes in that stage's `install.sh` and `rollback.sh` on purpose, and re-run its tests.

## Packaging

```sh
tools/fetch-vendor.sh          # stage 2 only
tools/package.sh stage1-wifi   # or stage2-lcd, stage3-mqtt
```

writes `build/packages/<stage>/` (installer, payload, `SHA256SUMS`) and `build/packages/<stage>.tar.gz`. The stage 2 payload is identical to the package that was installed and tested on the camera. The stage 3 payload differs only in `doorview-mqtt`, which was rebuilt after code review (see [known limits](known-limits.md)). The stage 2 and 3 installers were changed after review (a mandatory manifest entry for every file; the backup of the replaced file is kept when the automatic restore fails). The stage 3 installer has since run on the camera; the stage 2 installer has been run only by the fixture tests.

## Tests

```sh
tests/run-all.sh
```

| Suite | What it covers | Needs |
|---|---|---|
| `firmware/stage1-wifi/tests` (74) | installer, rollback and `configure.sh` on temporary trees: refusals, exact restoration after an injected failure, modes, no credentials in output | POSIX shell |
| `firmware/stage2-lcd/tests` (53) | installer and rollback; the selection logic of `S41doorview-network` (IRQ preferred, polling fallback, heartbeat restore) and `S96doorview-lcd` with stubbed commands | POSIX shell |
| `firmware/stage3-mqtt/tests` (63) | installer, rollback, `configure.sh` (rejects hostnames, over-long values, symlinks) and `S97doorview-mqtt` with a stub daemon | POSIX shell |
| `firmware/userland/mqtt/tests` (49) | the daemon against a real Mosquitto with authentication and ACLs: discovery, retained state, button de-duplication, capacity validation, last will after `kill -9`, reconnect, wrong password, ACL denial | Docker |
| `tools/tests` (29) | `make-wifi-config.py` and `jffs2-files.py` | Python 3 |

The installer tests only prove the **logic** of the installers on a fake root. They cannot prove how the real overlay behaves. Where a test is a safety property (a refusal that must change nothing, a rollback that must restore the exact tree), it was checked by mutation: a deliberately broken copy of the installer must make the suite fail. Several tests were found vacuous that way and fixed.
