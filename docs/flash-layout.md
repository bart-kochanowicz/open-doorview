# Flash backup and layout

## Current status

The chip on the verified unit is a Winbond W25Q64JW (reported by `flashrom` as `W25Q64.W`, 8192 kB, SPI) and U-Boot identifies it as ID `0xef 0x60 0x17`, 64 KiB blocks, 8 MiB. Two complete reads with `flashrom 1.8.0` and a CH341A produced files of 8,388,608 bytes with identical SHA-256. A matching pair proves consistent reads, not that the contents can be written back. The restoration procedure has never been tested.

The chip's supply and signals are 1.8 V: use a programmer or adapter that protects both, as described below.

## Backup procedure

This is a read-only procedure. It does not authorize erasing, writing, changing bootloader settings or removing the chip.

1. Confirm the chip marking, datasheet, supply and signal voltage range, package dimensions, pin 1 and clip orientation. Verify the programmer and any 1.8 V adapter protect **both supply and all signal lines**, and verify compatibility with the actual chip and clip.
2. Disconnect the camera battery and USB power. Check for other power sources. Do not connect two independent supplies to the same rail.
3. Connect the programmer only after the electrical checks. Identify the chip with `flashrom -p ch341a_spi`; confirm that the detected part and capacity match the physical chip. Stop if identification fails or differs. A successful identification is not proof that the circuit is electrically safe.
4. Read the entire chip twice into **different files in a private directory outside this repository**. For example, after changing to that directory:

   ```sh
   flashrom -p ch341a_spi -r backup_a.bin
   flashrom -p ch341a_spi -r backup_b.bin
   shasum -a 256 backup_a.bin backup_b.bin
   ```

5. Check both command exit statuses, each file's size against the confirmed chip capacity, and that the SHA-256 hashes match. Preserve the original reads and checksums securely in more than one private location; analyze copies. Matching hashes show consistent reads, but do not alone prove correctness or restorability.
6. Record chip identification, tool version, wiring, power setup, file sizes and hashes without disclosing sensitive contents.

If reads fail, identification is inconsistent or hashes differ, stop. Investigate clip contact, bus contention and back-powering; do not repeatedly proceed as if the backup were valid. Chip removal is a separate, potentially irreversible operation requiring explicit approval.

## Analysis record

Offsets observed in the factory image (an 8 MiB dump of the unit) and in the OpenIPC image that replaces it. "Observed structure" means data of that type was found at the offset; it is not a published partition table. Both are from analysis copies; the originals were not modified.

### Factory firmware

| Region | Offset | Evidence / confidence |
|---|---|---|
| Boot loader copies (gzip streams named `u-boot.bin`) | `0x4620`, `0x1c290` | gzip integrity passes; observed structure |
| U-Boot environment | `0x50000`, 64 KiB | CRC32 matches; `bootargs=console=ttyAMA0,115200n8 root=/dev/mtdblock2 rw`, `bootcmd=sf probe 0;quickstart;sf read 0x41000000 0x80000 0x560000;ugzip 0x41000000 0x40000000;go 0x40000000;` |
| Application image (gzip, an RTOS image named `p2pcam.bin`, load address `0x40000000`) | `0x80010` | gzip integrity passes |
| JFFS2 data | `0x5e0000`, `0x650000`, `0x690000` | extracted with no node or data CRC error; holds device identity, the MAC address, cloud keys and settings: **private** |

The factory firmware is an RTOS, not Linux. Its build strings select GK7202V300; its hardware configuration names GK7202EV300 and a GC2053 sensor. The physical SoC marking should still be confirmed on your board.

### OpenIPC (as installed)

| Region | Offset | Evidence / confidence |
|---|---|---|
| U-Boot | `0x0` to `0x40000` | U-Boot 2022.10 boot log |
| U-Boot environment | `0x40000` to `0x50000` | OpenIPC layout |
| Linux kernel (uImage) | `0x50000` to `0x230000` | "Found Kernel at 0x00050000", `Linux-4.9.37-gk7202v300`, 1,903,572 bytes |
| SquashFS root file system | `0x230000` to `0x800000` | "Found RootFS at 0x00230000" |
| Writable `rootfs_data` JFFS2 overlay | `0x750000` to `0x800000` (720,896 bytes) | `/dev/mtdblock5`, mounted at `/overlay` |

End offsets are exclusive. The installers in this repository write only to the overlay.

Analyze copies with tools such as `file`, `binwalk`, `strings` and `xxd`. Tool output, extracted files and logs can contain secrets too. Never publish complete dumps or unique calibration, identity or credential data.
