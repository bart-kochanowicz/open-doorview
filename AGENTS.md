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
| `docs/` | procedures (`flash-layout.md`, `uart-pinout.md`, `openipc-flash.md`), hardware notes (`wifi-companion.md`, `lcd-and-button.md`, `mqtt-home-assistant.md`), `troubleshooting.md`, `known-limits.md`, `building.md` |
| `firmware/stage1-wifi`, `stage2-lcd`, `stage3-mqtt` | installable packages: installer, rollback, payload, tests. The stages form a chain; later installers pin the exact files of earlier ones by SHA-256 |
| `firmware/kernel/` | source of every kernel module, one directory per module |
| `firmware/userland/` | LCD/button programs and the MQTT daemon |
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
| Serial diagnostics, verified SPI backup (two identical reads), firmware analysis | done; the factory restore path was never tested |
| OpenIPC compatibility | confirmed on one unit (GK7202V300, Linux 4.9.37) |
| Wi-Fi, RTSP/HTTP | works at 640×360, 5 fps (stage 1 and 2) |
| LCD preview and front button | works (stage 2) |
| MQTT / Home Assistant | stage 3 installed on the camera (2026-11-20) with the newer daemon and `motion=1`: connects to the broker, publishes discovery and state, reconnects after reboots; hours of runtime, three reboots; the motion sensor works in hand-waving tests; the broker is separate infrastructure, not in this repository |
| Battery monitoring | MCU power frames decoded; capacity scale and charge state unconfirmed |
| Reliable startup, recovery, update | startup works after a cold start; no automatic Wi-Fi reconnect; no OTA |

## Next work (in a sensible order)

1. Observe stage 3 and the motion sensor over days: Home Assistant values (battery, USB, button, motion), broker outages, reconnects, false alarms (tune `motionDetect` sensitivity and region of interest). Stages 1 and 2 set no default route; stage 3 adds it from `gateway=` in `mqtt.conf`. Next for the goal "notify when someone is at the door": the optional `snapshot=1` publishes a picture to the broker on the Motion edge (Home Assistant never reaches the camera). Do NOT create a second web account or open the camera's port 80 to Home Assistant: the web interface has no roles and every account is a root-equivalent administrator.
2. Wi-Fi health: understand the dead-data-path state, then decide on a reconnect or watchdog that is proven to recover (the optional `wifi_watchdog` is unproven and off).
3. Long-run stability of the interrupt-driven driver (only about 100 minutes observed) and the cause of the early-boot resets (two before every successful software reboot so far).
4. Signal strength and access-point info (needs the RSSI query; warn first).
5. Battery: confirm the capacity scale and the meaning of status 2 by observing a discharge and a full charge.
6. PIR: check whether the sensor is usable (`support_pir=1` in the factory config).
7. Person detection: the camera triggers and sends a frame, a server classifies, Home Assistant notifies (the SoC has one core, about 27 MB of RAM for Linux and no NPU).
8. Close the gaps in `docs/known-limits.md`: the unrecorded first-flash method, the lost source of the shipped `syslink_bg.ko`, non-reproducible LCD binaries, a licence file.

## Evidence Checklist

- [x] UART serial logs capture
- [x] Verified SPI flash backup
- [ ] Complete firmware analysis (the factory RTOS is only partly analysed)
- [ ] Hardware inventory documented (`docs/hardware-inventory.md` still has open items)
- [x] OpenIPC compatibility confirmed (one unit)
- [ ] Recovery procedures validated (restoring the factory flash and the overlay was never tested)
