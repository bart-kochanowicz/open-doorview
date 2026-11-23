# Host tools

Run these on your computer. The ones that talk to the camera need `DOORVIEW_UART` set to the serial device, only one program may use the port at a time, and none of them accepts the root password on the command line.

| Tool | Purpose |
|---|---|
| `uart-cmd.py '<command>'` | runs one shell command on the camera over the UART and prints its output (password on stdin) |
| `upload-archive.py <archive.tar.gz> <password-file>` | sends an archive as base64 over the UART with echo off, checks its SHA-256 on the camera, and unpacks it into `/tmp/doorview-upload` (never `/tmp/lcd-vo-test`: that is the LCD service's runtime directory) |
| `backup-overlay.py <out.bin>` | reads `/dev/mtdblock5` (the writable overlay) read-only over the UART (password on stdin) |
| `capture-reboot.py <log>` | logs in, records uptime and the SDIO counters, runs `reboot`, and keeps logging the boot, with the password redacted |
| `jffs2-files.py list\|cat <image> ...` | reads files out of a JFFS2 image or a flash dump without mounting it (used to read the factory MAC) |
| `make-wifi-config.py` | creates `station.hex`, `address` and `mac` for stage 1 |
| `fetch-vendor.sh` | downloads the proprietary vendor video module and checks its hash |
| `package.sh <stage>` | assembles the installable package and archive for a stage |
| `build.sh`, `build-in-container.sh`, `extract-rootfs-libs.sh`, `pins.sh`, `build/Dockerfile` | the reproducible build ([docs/building.md](../docs/building.md)); the earlier stage sources come from git history |
| `format.sh [--check]`, `format/Dockerfile` | formats the C sources with clang-format ([docs/building.md](../docs/building.md#formatting)) |
| `tests/run-tests.sh` | tests for the helpers that need no camera |

`capture-reboot.py` reboots the camera. Everything else here is read-only on the camera except `upload-archive.py`, which only writes to `/tmp` (RAM).
