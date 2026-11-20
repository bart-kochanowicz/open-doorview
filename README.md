# Open Doorview

Open firmware work for the **RH-PD10 smart door peephole camera**: replacing the factory firmware with [OpenIPC](https://openipc.org/) and adding the pieces OpenIPC does not have for this board. The goal is a local door viewer with no cloud: an RTSP/HTTP stream over Wi-Fi, the front button and LCD, and battery, power and button state in Home Assistant over MQTT.

The work is evidence-driven. Each claim in the documentation says whether it was observed on the unit, read from the factory firmware, or assumed.

## What works

Developed and tested on **one** RH-PD10 (Goke GK7202V300, 8 MiB SPI NOR, GC2053 sensor, 480 × 272 LCD, Wi-Fi/battery/button on a separate coprocessor).

| | Status |
|---|---|
| OpenIPC boots from flash (Linux 4.9.37, Majestic) | works |
| Wi-Fi (2.4 GHz WPA2, static IPv4) through the coprocessor | works; needs our SDIO drivers, which are in [`firmware/kernel/`](firmware/kernel) |
| RTSP and HTTP video | works at 640 × 360, 5 fps; 1080p is too slow over the SDIO link |
| Front button lights the LCD with a 30 s live preview | works |
| Battery, USB and button as MQTT/Home Assistant entities | works from RAM; persistent install not done |

What is **not** done or not known (battery scale, charge state, PIR, audio, DHCP, reconnect, person detection and more) is in [known limits](docs/known-limits.md). Please read it before you flash.

## Start here

1. **[Install guide](docs/install-guide.md)**: from a factory camera to everything above, step by step, with checks and rollbacks.
2. [Back up the factory flash](docs/flash-layout.md#backup-procedure) and [install OpenIPC](docs/openipc-flash.md).
3. Background: [the Wi-Fi/battery coprocessor](docs/wifi-companion.md), [LCD and button](docs/lcd-and-button.md), [MQTT and Home Assistant](docs/mqtt-home-assistant.md).
4. [Troubleshooting](docs/troubleshooting.md), [building and testing](docs/building.md).

## Repository map

| Path | Contents |
|---|---|
| `docs/` | install guide, hardware notes, procedures, known limits |
| `firmware/stage1-wifi`, `stage2-lcd`, `stage3-mqtt` | installable packages: installer, rollback, payload, tests ([overview](firmware/README.md)) |
| `firmware/kernel/` | source of the SDIO/Wi-Fi kernel modules |
| `firmware/userland/` | LCD and button programs, the MQTT daemon |
| `tools/` | host-side helpers: UART upload and backup, Wi-Fi configuration, JFFS2 reader, build and packaging scripts |
| `tests/run-all.sh` | every test suite that does not need a camera |
| [`AGENTS.md`](AGENTS.md) | operating and approval rules for the project |

Binaries are included only where they were tested on a camera and are listed with their hashes in `firmware/EXPECTED-BUILDS.txt`. The factory firmware, flash dumps, extracted factory files and the proprietary vendor video module are **not** in this repository.

## Workflow

1. **Diagnose:** identify the board and capture a complete boot cycle through passive UART.
2. **Preserve:** identify the flash and obtain two matching, complete reads before considering modifications.
3. **Analyze:** work on copies of the backup and document findings, including the actual [flash layout](docs/flash-layout.md).
4. **Investigate compatibility:** confirm the exact SoC and supporting hardware before evaluating OpenIPC or other platforms.
5. **Develop and integrate:** establish a recoverable boot path, then investigate camera, networking, local streaming, Home Assistant, display and power management.

Each stage depends on evidence from the previous stages. A matching backup alone does not prove that restoration works; recovery must be validated separately.

## Safety and privacy

- Never erase or write flash, modify the bootloader environment, or perform another potentially irreversible hardware operation without explicit approval immediately beforehand. Never overwrite original flash before a complete, verified backup exists.
- Validate the voltage, wiring and chip orientation before connecting a programmer. Disconnect the camera battery and USB power during external SPI programming. Do not connect independent power sources to the same rail.
- Begin UART capture with camera TX → adapter RX and common ground only. Validate levels before connecting adapter TX; do not use the UART supply pad to power the device.
- Original dumps and serial logs can contain credentials, tokens and device identifiers. Store them privately outside the repository, keep secure copies, and sanitize excerpts before sharing. The ignore rules are a precaution, not a guarantee against disclosure.
- Do not assume compatibility from a suspected SoC or flash an image merely because it looks similar.

See [AGENTS.md](AGENTS.md) for the complete operating rules and the [backup procedure](docs/flash-layout.md#backup-procedure) for prerequisites.
