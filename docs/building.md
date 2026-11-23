# Building and testing

The repository ships the exact binaries that were tested on a camera (in the `payload/` directory of each stage). You only need to build if you want to check them, change the source, or target a different kernel.

## What is built from what

| Output | Source | Toolchain | Reproduces the tested binary? |
|---|---|---|---|
| `syslink_poll.ko`, `syslink_net.ko` (stage 1), `syslink_net_irq.ko` (the current driver, stage 12) | `firmware/kernel/` | Debian 12 `gcc-arm-linux-gnueabi` 12.2.0, OpenIPC Linux 4.9.37 tree | **Yes, bit for bit** (verified from a clean Docker image and a fresh shallow clone) |
| the earlier stage binaries: `syslink_poll-stage1.ko`, `syslink_net_irq-stage2.ko` to `-stage6.ko`, `doorview-mqtt-stage3` to `-stage12` | git history at `OLD_SOURCES_COMMIT` (`tools/pins.sh`), extracted by `tools/build.sh` into `build/old-src/` | same | **Yes, bit for bit**; needs a clone with that commit (not a shallow one) |
| `doorview-mqtt` (stage 13) | `firmware/userland/mqtt/` (`doorview-mqtt.c` includes `parts/*.c`: one translation unit) | same compiler, freestanding, `-Os -mfloat-abi=soft -march=armv7-a` | **Yes, bit for bit** |
| `button-preview`, `vo-live-30` | `firmware/userland/lcd/` | same compiler | **No.** The tested binaries came from command lines that were not recorded. A rebuild is the same source but not identical, and has not been tried on a camera |
| `first-snap` (a measurement prototype, see [first-snap](first-snap.md)) | `firmware/userland/capture/` | same compiler, linked against the OpenIPC `libc.so`, the vendor libraries and the stage 2 compatibility library | Not applicable: no working binary yet (it crashes in `GK_API_SYS_Init` on the unit) |
| `syslink_bg.ko` | `firmware/kernel/syslink-handshake/syslink_bg.c` | same | **No.** The shipped binary was built from an earlier revision of the source that was not kept; see [known limits](known-limits.md) |
| `libuclibc-compat.so` | OpenIPC `general/package/uclibc-compat` (MIT) | not rebuilt | Shipped as tested; a rebuild from the current upstream source gave a different file |
| `vo.ko` | OpenIPC `goke-osdrv-gk7205v200` (proprietary) | not built | Downloaded by `tools/fetch-vendor.sh`, hash-checked, never stored here |

`firmware/EXPECTED-BUILDS.txt` lists the hash of every tested binary and its status; `tools/build.sh` compares against it.

## Rebuilding

Needs Docker and network access. It builds a Debian 12 image, fetches the pinned kernel source (a shallow clone of one commit of `OpenIPC/linux`), takes the kernel configuration from OpenIPC's firmware repository, builds the modules out of tree, and compares hashes.

```sh
tools/build.sh
```

To also rebuild `vo-live-30` (and build `first-snap`) you need libraries from the OpenIPC root file system. Extract them from the image you flashed:

```sh
tools/extract-rootfs-libs.sh openipc-gk7202v300-nor-lite-8mb.bin     # fills build/rootfs-libs/
tools/build.sh
```

Output goes to `build/out/{kernel,userland}/`. All pins (kernel commit, config path, headers commit, vendor module hash) are in `tools/pins.sh`.

If you use a different OpenIPC image than the one in [openipc-flash.md](openipc-flash.md), the kernel configuration may differ. The modules carry no symbol versioning, so a module only loads if the vermagic string is identical (`4.9.37 mod_unload ARMv7 p2v8`); check with `modinfo` on the camera, and compare the `.config` your image was built from with the one the script fetches.

### Using your own build

The installers check the hash of the files they replace. The chain is: stage 2 requires the exact stage 1 `S41doorview-network` and `syslink_net.ko`; stage 3 requires the exact stage 2 `syslink_net_irq.ko`. All of these reproduce bit for bit, so a rebuild fits. If you change source, you change a hash and the next stage's installer will refuse: edit the pinned hashes in that stage's `install.sh` and `rollback.sh` on purpose, and re-run its tests.

## Formatting

```sh
tools/format.sh            # rewrite the C sources in firmware/
tools/format.sh --check    # change nothing; fail on a file that is not formatted (tests/run-all.sh runs this)
```

clang-format 14 from Debian 12, in a Docker image of its own (`tools/format/Dockerfile`) so that it can never change the pinned compiler, with the style in `.clang-format` (4 spaces, 120 columns, the brace placement of the existing code). Formatting must not change a binary: after it, `tools/build.sh` must still report every reproducible binary as identical. That held when the sources were first formatted (2026-11-23): no source uses `__LINE__` or `__FILE__`, and the modules carry no `srcversion`. The installed shell scripts are not formatted: the installers pin them by hash.

## Packaging

```sh
tools/fetch-vendor.sh          # stage 2 only
tools/package.sh stage1-wifi   # or any other stage directory name
```

writes `build/packages/<stage>/` (installer, payload, `SHA256SUMS`) and `build/packages/<stage>.tar.gz`. The stage 2 payload is identical to the package that was installed and tested on the camera. The stage 3 payload differs only in `doorview-mqtt`, which was rebuilt after code review (see [known limits](known-limits.md)). The stage 2 and 3 installers were changed after review (a mandatory manifest entry for every file; the backup of the replaced file is kept when the automatic restore fails). The stage 3 installer has since run on the camera; the stage 2 installer has been run only by the fixture tests.

## Tests

```sh
tests/run-all.sh
```

| Suite | What it covers | Needs |
|---|---|---|
| `firmware/stage1-wifi/tests` | installer, rollback and `configure.sh` on temporary trees: refusals, exact restoration after an injected failure, modes, no credentials in output | POSIX shell |
| `firmware/stage2-lcd/tests` | installer and rollback; the selection logic of `S41doorview-network` (IRQ preferred, polling fallback, heartbeat restore) and `S96doorview-lcd` with stubbed commands | POSIX shell |
| `firmware/stage3-mqtt/tests` | installer, rollback, `configure.sh` (rejects hostnames, over-long values, symlinks) and `S97doorview-mqtt` with a stub daemon | POSIX shell |
| `firmware/stage4-sleep/tests` to `firmware/stage13-night-wait/tests` | each installer and rollback on fixture trees: the pins of the files it replaces, refusals that change nothing, the automatic exact rollback, modes; the boot scripts of stages 8 to 11 with stubbed commands | POSIX shell |
| `firmware/userland/mqtt/tests` (about 290 checks) | the daemon against a real Mosquitto with authentication and ACLs, a stand-in for Majestic and a fake kernel log, also built with ASan/UBSan: discovery, state, buttons, motion, snapshots, the live view, the sleep, the PIR, the night wait, `wifi_reboot`, the configuration checks | Docker, a C compiler, Python 3 |
| `tools/tests` | `make-wifi-config.py` and `jffs2-files.py` | Python 3 |
| `tools/format.sh --check` | the C sources are formatted | Docker |

The installer tests only prove the **logic** of the installers on a fake root. They cannot prove how the real overlay behaves. Where a test is a safety property (a refusal that must change nothing, a rollback that must restore the exact tree), it was checked by mutation: a deliberately broken copy of the installer must make the suite fail. Several tests were found vacuous that way and fixed.
