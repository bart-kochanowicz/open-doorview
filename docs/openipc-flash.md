# Installing OpenIPC on the RH-PD10

This replaces the factory firmware on the SPI flash with the OpenIPC "lite" image for the Goke GK7202V300. It is the one step in this project that **erases and rewrites the whole chip**. Do it only after you have two identical, verified reads of the factory flash ([backup procedure](flash-layout.md#backup-procedure)).

> **Evidence gap.** The unit this repository was developed on was flashed before the repository's records began, and the exact command sequence used for that first flash was not recorded. What *is* recorded is the starting point (two identical factory reads), the image that was prepared, and what the camera's U-Boot reported after the flash (below). The two methods in this document follow the upstream OpenIPC and programmer documentation and are not replays of recorded steps. Treat them as a plan to verify, and stop if anything differs from what is described here.

## The image

OpenIPC builds an image per SoC, flash size and release, and offers it through its site:

- `https://openipc.org/cameras/vendors/goke/socs/gk7202v300/download_full_image?flash_size=8&flash_type=nor&fw_release=lite`

The image prepared on 2026-11-17 for this project:

| Property | Value |
|---|---|
| Size | 8,388,608 bytes (the full 8 MiB chip) |
| SHA-256 | `ffd93ec0a08a7d69d861ab49ad13d4f443392507bf7950df234d1506b301e2cc` (computed locally; the publisher does not list a checksum for generated images) |
| U-Boot | gzip stream at `0x4770`; `U-Boot 2022.10-g8f4692eb (Nov 17 2026 - 08:19:59)` |
| Kernel | uImage at `0x50000`: `Linux-4.9.37-gk7202v300`, 1,903,572 bytes, CRCs valid |
| Root file system | SquashFS at `0x230000`, 5,324,462 bytes |
| Sensor | GC2053 profile and library included |

The generated image changes when OpenIPC publishes a new build. **The kernel modules in this repository are built for this kernel** (vermagic `4.9.37 mod_unload ARMv7 p2v8`, no symbol versioning). A newer image may load them or may not; check `uname -r` and `modinfo` before installing a stage, and rebuild ([building](building.md)) if the kernel configuration changed.

Check what you downloaded before using it:

```sh
ls -l openipc-gk7202v300-nor-lite-8mb.bin          # 8388608 bytes
shasum -a 256 openipc-gk7202v300-nor-lite-8mb.bin
```

If the hash differs from the one above, you have a different build: compare its kernel header (`Linux-4.9.37-gk7202v300`) and the U-Boot version printed on first boot with the table before going on.

## What it overwrites

The full image covers the whole chip. Compared with the factory layout:

| Factory firmware (observed) | OpenIPC (observed) |
|---|---|
| Bootloader copies in the first 0x50000 bytes | U-Boot at `0x0`, `0x40000` bytes reserved |
| U-Boot environment at `0x50000` (64 KiB, CRC valid) | environment at `0x40000`; kernel at `0x50000` |
| RTOS application image (`p2pcam`, gzip) at `0x80010` | SquashFS root file system at `0x230000` |
| JFFS2 data at `0x5e0000`, `0x650000`, `0x690000` (device identity, MAC, cloud keys, settings) | writable `rootfs_data` JFFS2 overlay at `0x750000` (720,896 bytes) |

Everything unique to your unit lives in the factory data. After the write it exists only in your backup. Keep it.

## Method A: SPI programmer (recommended)

This does not depend on what is currently in the camera, so it also works on a camera that no longer boots. Use exactly the wiring, 1.8 V adapter and precautions you validated for the backup; they are not repeated here.

1. Disconnect the battery and USB. Attach the clip and confirm identification:

   ```sh
   flashrom -p ch341a_spi
   ```

   It must report the same chip you backed up (`W25Q64.W`, 8192 kB on the verified unit). Stop if it does not.
2. Write and verify:

   ```sh
   flashrom -p ch341a_spi -w openipc-gk7202v300-nor-lite-8mb.bin
   flashrom -p ch341a_spi -v openipc-gk7202v300-nor-lite-8mb.bin
   ```

   `-w` already verifies; the separate `-v` is a second look. Both exit codes must be 0.
3. Remove the clip, reconnect only the UART (camera TX → adapter RX, ground), then power the camera with USB and read the boot log.

If a write or verify fails, **do not power the camera and do not retry blindly**. Re-seat the clip, read the chip twice, compare, and investigate bus contention and back-powering. A partially written chip is recoverable with the programmer as long as you do not boot it.

## Method B: UART (OpenIPC's defib and U-Boot)

This loads a boot loader into RAM over the UART with a burn tool, then writes the flash from U-Boot. It needs the adapter's TX connected (so the 1.8 V level must be validated) and a working boot ROM. The commands below are those in the README of a third-party GK7202V300 build system (`ictu-dungnt98/gk7202v300_build_system`); they have **not** been run by this repository. OpenIPC maintains its own tool for this, [`defib`](https://github.com/OpenIPC/defib), which lists the `gk7202v300`; its source was reviewed at commit `5167b2a` but no recovery command was ever executed. Compare everything with the current OpenIPC documentation first.

```sh
# on the host, with the camera powered off, then power it on when asked
./burn --chip gk7202v300 --file=u-boot-gk7202v300-universal.bin --break
picocom -b 115200 --databits 8 --parity n --stopbits 1 --flow n /dev/ttyUSB0

# in U-Boot
setenv flashsize 0x800000
mw.b ${baseaddr} 0xff ${flashsize}
loady ${baseaddr}
# then send the image with YMODEM: !! sz --ymodem openipc-gk7202v300-nor-lite-8mb.bin
sf probe 0
sf lock 0
sf erase 0x0 ${flashsize}
sf write ${baseaddr} 0x0 ${filesize}
```

A warning from the project's own analysis: the factory U-Boot has a conditional recovery path (`bootfail`) that can run flash-writing commands, so an autonomous boot is not guaranteed to be read-only. Inspect what you load into RAM and keep the camera from booting on its own until you mean to.

## After the flash

On the first boot the UART should show, in this order:

```
U-Boot 2022.10-g8f4692eb (Nov 17 2026 - 08:19:59)
...
SPI Nor ID: 0xef 0x60 0x17 ... Name:"W25Q64FW/JW"
Automatic flash layout detection...
Found Kernel at 0x00050000
Found RootFS at 0x00230000 (5199k)
...
Linux version 4.9.37 ... #1 Mon Nov 16 17:56:34 UTC 2026
OF: fdt:Machine model: Goke GK7202V300 DEMO Board
```

then a login prompt. The writable overlay partition is set up on the first start, which can take a moment. Continue with [step 4 of the install guide](install-guide.md#step-4-first-boot-and-checks).

The camera will not have Wi-Fi at this point: the Wi-Fi/battery coprocessor needs the handshake and drivers from [stage 1](install-guide.md#step-6-stage-1-wi-fi-base). Until then the UART is your only way in.
