# Open Doorview

Open firmware work for the **RH-PD10 smart door peephole camera**: replacing the factory firmware with [OpenIPC](https://openipc.org/) and adding the pieces OpenIPC does not have for this board. The goal is a local door viewer with no cloud: an RTSP/HTTP stream over Wi-Fi, the front button and LCD, and battery, power and button state in Home Assistant over MQTT.

The work is evidence-driven. Each claim in the documentation says whether it was observed on the unit, read from the factory firmware, or assumed.

## What works

Developed and tested on **one** RH-PD10 (Goke GK7202V300, 8 MiB SPI NOR, GC2053 sensor, 480 × 272 LCD, Wi-Fi/battery/button on a separate coprocessor).

| | Status |
|---|---|
| OpenIPC boots from flash (Linux 4.9.37, Majestic) | works |
| Wi-Fi (2.4 GHz WPA2, static IPv4) through the coprocessor | works; needs our SDIO drivers, which are in [`firmware/kernel/`](firmware/kernel) |
| **Sleep like the factory firmware** | works (stages 4 to 10): sleeps after 60 s without activity, wakes by the PIR or a button; a PIR wake-up reaches a "person at the door" alert in Home Assistant about 12 s after power-on (measured; the person check runs on a home server) |
| Snapshots and live view over MQTT | works (960 × 540 snapshots after motion; small frames on demand); Home Assistant never reaches the camera |
| Night vision (IR-cut filter and IR LEDs) | works through Majestic with one GPIO (8), see [night vision](docs/night-vision.md) |
| RTSP and the web interface | possible (stages 1 to 3), but **switched off on the unit** for start-up time and security; the web interface is an administrator interface with no roles |
| Front button lights the LCD with a 30 s live preview | works while the camera is awake |
| Battery, USB and button as MQTT/Home Assistant entities | works (stage 3 and later); while the camera sleeps they are unavailable, the homelab keeps the last battery reading |

What is **not** done or not known (battery scale, charge state, PIR, audio, DHCP, reconnect, person detection and more) is in [known limits](docs/known-limits.md). Please read it before you flash.

## Start here

1. **[Install guide](docs/install-guide.md)**: from a factory camera to everything above, step by step, with checks and rollbacks.
2. [Back up the factory flash](docs/flash-layout.md#backup-procedure) and [install OpenIPC](docs/openipc-flash.md).
3. Background: [the Wi-Fi/battery coprocessor](docs/wifi-companion.md), [how the factory firmware sleeps and detects people](docs/factory-firmware.md), [LCD and button](docs/lcd-and-button.md), [MQTT and Home Assistant](docs/mqtt-home-assistant.md).
4. [Troubleshooting](docs/troubleshooting.md), [building and testing](docs/building.md).

## Repository map

| Path | Contents |
|---|---|
| `docs/` | install guide, hardware notes, procedures, known limits |
| `firmware/stage1-wifi`, `stage2-lcd`, `stage3-mqtt`, `stage4-sleep`, `stage5-sleep-daemon`, `stage6-wake-timer`, `stage7-pir-motion`, `stage8-fast-boot`, `stage9-lean`, `stage10-early-daemon`, `stage11-wake-preview` | installable packages: installer, rollback, payload, tests ([overview](firmware/README.md)) |
| `firmware/kernel/` | source of the SDIO/Wi-Fi kernel modules |
| `firmware/userland/` | LCD and button programs, the MQTT daemon |
| `tools/` | host-side helpers: UART upload and backup, Wi-Fi configuration, JFFS2 reader, build and packaging scripts |
| `tests/run-all.sh` | every test suite that does not need a camera |
| [`AGENTS.md`](AGENTS.md) | operating and approval rules for the project |

Binaries are included only where they were tested on a camera, with one caveat: the current `doorview-mqtt` (it adds the motion sensor) has run on the camera for hours, not days (see [known limits](docs/known-limits.md)). Their hashes, and whether a rebuild reproduces them, are in `firmware/EXPECTED-BUILDS.txt`. The factory firmware, flash dumps, extracted factory files and the proprietary vendor video module are **not** in this repository.

## How the work is organised

Each step depends on evidence from the one before; do not skip ahead.

1. **Preserve:** two matching, complete reads of the factory flash, kept privately ([flash layout](docs/flash-layout.md)). A matching backup alone does not prove that restoration works; that was never tested.
2. **Flash:** the OpenIPC image ([OpenIPC](docs/openipc-flash.md)).
3. **Install the stages in order:** Wi-Fi, LCD and button, MQTT ([install guide](docs/install-guide.md)). Each installer is a flash write with its own rollback.
4. **Continue the work:** the ordered list is in [AGENTS.md](AGENTS.md#next-work-in-a-sensible-order); open questions are in [known limits](docs/known-limits.md).

## Safety and privacy

- Never erase or write flash, modify the bootloader environment, or perform another potentially irreversible hardware operation without explicit approval immediately beforehand. Never overwrite original flash before a complete, verified backup exists.
- Validate the voltage, wiring and chip orientation before connecting a programmer. Disconnect the camera battery and USB power during external SPI programming. Do not connect independent power sources to the same rail.
- Begin UART capture with camera TX → adapter RX and common ground only. Validate levels before connecting adapter TX; do not use the UART supply pad to power the device.
- Original dumps and serial logs can contain credentials, tokens and device identifiers. Store them privately outside the repository, keep secure copies, and sanitize excerpts before sharing. The ignore rules are a precaution, not a guarantee against disclosure.
- Do not assume compatibility from a suspected SoC or flash an image merely because it looks similar.

See [AGENTS.md](AGENTS.md) for the complete operating rules and the [backup procedure](docs/flash-layout.md#backup-procedure) for prerequisites.
