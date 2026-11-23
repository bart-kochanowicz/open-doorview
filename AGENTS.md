# RH-PD10 Firmware Recovery Agent Operating Procedure

## Project Overview

This repository holds the recovery procedures and the custom firmware layer for the RH-PD10 smart door peephole camera: OpenIPC plus our own Wi-Fi/SDIO drivers, LCD and button service, and an MQTT publisher for Home Assistant. It is the reference for anyone flashing their own unit and for agents continuing the work. The project follows a careful, evidence-based approach; the sections below give the safety rules, the repository map, working rules, the current state and the next work.

## Safety Rules (Non-Negotiable)

1. **Never erase or overwrite original flash** before obtaining and verifying a complete backup.
2. **Never connect a 3.3 V or 5 V signal directly** to confirmed 1.8 V logic.
3. **Verify CH341A output voltage, signal voltage, adapter wiring, pin 1 orientation, and chip compatibility** before connecting it to flash.
4. **Disconnect the device battery and USB power** before external SPI programming.
5. **Never connect two independent power sources** to the same rail without a verified electrical design.
6. **Prefer passive UART reception initially**: device TX to adapter RX, plus common GND. Do not connect adapter TX until its voltage has been validated.
7. **Never flash an OpenIPC image based only on a suspected processor family**.
8. **Do not overwrite bootloader, calibration, device identity, MAC addresses, or other unique partitions** without explicit approval.
9. **Do not execute destructive flash commands automatically**.
10. **Ask for explicit approval immediately** before any flash erase/write, bootloader environment modification, or other potentially irreversible hardware operation.
11. **Preserve original binary images securely**. They may contain Wi-Fi credentials, tokens, or unique device secrets. Do not publish complete dumps to public Git repositories.
12. **If in-circuit programming is unreliable**, stop and report the risk of bus contention or back-powering. Consider chip removal only as an explicitly approved later option.

## Repository map

| Path | What it is |
|---|---|
| `README.md`, `docs/install-guide.md` | what works and the end-to-end install |
| `docs/` | procedures (`flash-layout.md`, `uart-pinout.md`, `openipc-flash.md`), hardware notes (`wifi-companion.md`, `factory-firmware.md`, `lcd-and-button.md`, `mqtt-home-assistant.md`), `troubleshooting.md`, `known-limits.md`, `building.md` |
| `firmware/stage1-wifi`, `stage2-lcd`, `stage3-mqtt`, `stage4-sleep`, `stage5-sleep-daemon`, `stage6-wake-timer`, `stage7-pir-motion`, `stage8-fast-boot`, `stage9-lean`, `stage10-early-daemon`, `stage11-wake-preview` | installable packages: installer, rollback, payload, tests. The stages form a chain; later installers pin the exact files of earlier ones by SHA-256 |
| `firmware/kernel/` | source of every kernel module, one directory per module |
| `firmware/userland/` | LCD/button programs, the MQTT daemon, and `capture/first-snap.c` (a measurement prototype, never run) |
| `firmware/EXPECTED-BUILDS.txt` | hashes of the binaries tested on a camera, and whether a rebuild reproduces them |
| `tools/` | host-side helpers (UART, backup, packaging, build); see `tools/README.md` |
| `tests/run-all.sh` | every suite that needs no camera |

Private material lives **outside** the repository (flash dumps, overlay backups, UART logs, the root password, Wi-Fi credentials). `.gitignore` is a precaution, not a control.

## Working rules

- **Read first:** `docs/known-limits.md` and the hardware notes for the area you touch. Do not repeat the failures listed in `docs/wifi-companion.md` and `docs/troubleshooting.md`.
- **Never send a command to the Wi-Fi/battery MCU that the shipped drivers do not already send.** One such experiment silenced the UART and needed a power-button press. Warn the owner before any new MCU command (the RSSI query `0x28` is the known candidate).
- **Passive before active** on the UART: capture a boot before sending anything after a silence.
- **Every flash write needs approval immediately beforehand**, including each installer in `firmware/` and `/etc/majestic.yaml`. Take a fresh overlay backup (two identical reads) first; the overlay changes with every install.
- **Secrets:** the root password and Wi-Fi credentials never go on a command line, into a log, a commit or chat. Use the silent upload and the redacting helpers in `tools/`.
- **Evidence labels:** in docs say whether a fact was observed on the unit, read from the factory firmware, or assumed. One camera was used; do not generalise.
- **Tests:** run `tests/run-all.sh` before and after changing an installer or the daemon. A safety property (a refusal that must change nothing, an exact rollback) is only proven if a deliberately broken copy makes the suite fail; do that mutation check for new ones. Installer tests prove logic on a fake root, not behaviour on the real overlay.
- **Installers:** keep their properties (mount check, no overwrite, hash-verified stage, hooks last, automatic exact rollback, no credentials in output). Changing a shipped file changes a hash that the next stage pins; update the pin and its tests deliberately.
- **Binaries:** only add a binary to a `payload/` directory after it ran on a camera, and record its hash in `firmware/EXPECTED-BUILDS.txt`. If a shipped binary must be rebuilt (for example after a review fix) before it can be run on a camera, say so in `docs/known-limits.md` and the README until it has, and prefer a bit-identical reproducible build. Proprietary vendor blobs are downloaded, never committed. Do not publish factory firmware, dumps or extracted factory files.
- **Style:** docs and code comments in English. Keep the surrounding code's density and idiom.

## Current state

| Milestone | State |
|---|---|
| Serial diagnostics, verified SPI backup (two identical reads), firmware analysis | done; the factory restore path was never tested; the factory RTOS is analysed where it mattered (power cycle, PIR, wake-up reasons; `docs/factory-firmware.md`) |
| OpenIPC compatibility | confirmed on one unit (GK7202V300, Linux 4.9.37) |
| Wi-Fi | works through our SDIO drivers (stages 1 to 4, 6); data-path stalls still happen (one on 2026-11-23), recovered by `wifi_reboot` |
| Video | Majestic delivers the snapshots (960 × 540) and the live view frames over MQTT; RTSP, ONVIF, audio and the video motion detector are off and the web panel is hidden on the unit (install guide, step 14) |
| LCD preview and front button | works while the camera is awake (stage 2); a press that wakes the camera is consumed by the coprocessor |
| Sleep like the factory firmware | works (stages 4 to 10): the camera sleeps after 60 s without activity, wakes by the PIR (sensitivity 3, about 1 m), the power button or the front button, and reports a PIR wake-up as motion with a snapshot; the coprocessor's own 5-minute timer is off |
| Start-up time | U-Boot banner to Majestic 6.1 s, to the broker 5.6 s, to the person alert in Home Assistant 11.8 s (2026-11-23; what is left is in `docs/known-limits.md`) |
| MQTT / Home Assistant | stage 3 and later daemons; the homelab checks every snapshot for a person (two detectors) and sends the only phone notification for a person |
| Battery monitoring | MCU power frames decoded; the percentage follows the battery voltage; battery life in sleep mode not measured yet (it was 15 to 18 h without sleep) |
| Recovery, update | every stage has an exact rollback; `bootdelay` is 0, so U-Boot cannot be stopped on the UART (recovery: SPI programmer, failsafe boot, `fw_setenv bootdelay 1`); no OTA |

## Next work (in a sensible order)

1. **Measure the battery in sleep mode:** a day or more on the battery, with the wake-ups, the awake time and the last known battery value from Home Assistant. This decides whether more work on the power cycle is needed.
2. **Observe the sleep cycle over days:** false PIR wake-ups, missed visitors, the person detector's answers (collect real positives to tune its thresholds), Wi-Fi stalls during the short awake windows.
3. **Faster first picture:** Majestic needs about 3 s from its start to the first picture at a cold start (1.33 s at a warm restart). `firmware/userland/capture/first-snap.c` is that minimal capture program (written and cross-compiled, never run; `docs/first-snap.md` has the RAM-only measurement and what decides the next step); the live view would then need another source.
4. **Front button while asleep:** the press that wakes the camera does not start the LCD preview (the coprocessor consumes it). Stage 11 starts the preview after a `wifikey` wake-up; it is written and tested on a host, not installed yet.
5. Wi-Fi health: find the cause of the data-path stalls (driver, SDIO link or coprocessor; see `docs/wifi-companion.md`). `wifi_reboot` recovers; `wifi_watchdog` (a reconnect) is unproven and off.
6. The cause of the early-boot resets after a software reboot (two before every successful one; a cold start from the coprocessor does not have them).
7. Signal strength and access-point info (needs the RSSI query `0x28`, a new coprocessor command: warn first).
8. Battery: confirm the capacity scale and the meaning of status 2 by observing a discharge and a full charge.
9. Close the gaps in `docs/known-limits.md`: the unrecorded first-flash method, the lost source of the shipped `syslink_bg.ko`, non-reproducible LCD binaries, a licence file, mDNS on 5353.

Every new coprocessor command needs a warning to the owner first (the recovery from a silent coprocessor or a sleeping SoC is the power button); never send `8a:7e` with a non-zero value. Do NOT create a second web account or open the camera's port 80 to Home Assistant: the web interface had no roles and every account was a root-equivalent administrator.

## Evidence Checklist

- [x] UART serial logs capture
- [x] Verified SPI flash backup
- [ ] Complete firmware analysis (the factory RTOS is only partly analysed; the power cycle, PIR and wake-up reasons are)
- [ ] Hardware inventory documented (`docs/hardware-inventory.md` still has open items)
- [x] OpenIPC compatibility confirmed (one unit)
- [ ] Recovery procedures validated (restoring the factory flash and the overlay was never tested)
