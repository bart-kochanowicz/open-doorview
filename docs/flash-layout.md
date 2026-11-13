# Flash backup and layout

## Current status

No flash dump or partition map has been verified. The previously listed offsets and partition sizes were unsupported and must not be used. The initial notes report a Winbond `W25Q64JWSSIQ` (64 Mbit / 8 MiB), but the physical marking, package, voltage requirements and programmer identification must be checked against the exact chip's datasheet.

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

Populate this only from actual evidence. Record offsets, lengths, discovery method and confidence; distinguish tool guesses from confirmed boundaries.

| Region | Offset | Length | Evidence / confidence |
| --- | --- | --- | --- |
| Not yet established | — | — | No verified dump or boot log recorded. |

Analyze copies with tools such as `file`, `binwalk`, `strings` and `xxd`. Tool output, extracted files and logs can contain secrets too. Never publish complete dumps or unique calibration, identity or credential data.
