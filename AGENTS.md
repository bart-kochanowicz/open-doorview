# RH-PD10 Firmware Recovery Agent Operating Procedure

## Project Overview

This repository documents the recovery and custom firmware development for the RH-PD10 smart door peephole camera. The project follows a careful, evidence-based approach to diagnose hardware failures, backup original firmware, reverse engineer the system architecture, and develop safe custom firmware solutions.

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

## Phase A — Serial Boot Diagnostics

### Goal
Capture and analyze a complete boot cycle to identify reset causes, bootloader, kernel version, storage map, and potential failures.

### Tasks
1. Identify the serial adapter device under macOS.
2. Verify the Waveshare adapter's VCCIO configuration and 1.8 V logic level.
3. Determine which UART test pads connect to the main SoC.
4. Start passive serial capture.
5. Test a reasonable baud rate, beginning with 115200 8N1.
6. Reboot the camera and capture the entire sequence.
7. Preserve the raw logs.
8. Identify reset causes, bootloader, kernel version, storage map, and potential failures.

### Example Commands
```bash
ls /dev/cu.*
picocom -b 115200 /dev/cu.usbserial-XXXX
```

## Phase B — SPI Flash Backup

### Goal
Obtain a reproducible, verified image of original flash memory.

### Requirements
- Verify the exact chip identity against the datasheet.
- Confirm 1.8 V electrical operation.
- Verify the 1.8 V adapter protects both supply and signal lines.
- Confirm SOIC-8 clip orientation and compatibility with 208 mil packaging.
- Confirm battery and USB have been disconnected.

### Example Commands
```bash
flashrom -p ch341a_spi
flashrom -p ch341a_spi -r backup_a.bin
flashrom -p ch341a_spi -r backup_b.bin
shasum -a 256 backup_a.bin backup_b.bin
```

## Phase C — Firmware Analysis

### Goal
Analyze the backed-up image without modifying the original.

### Analysis Scope
- Bootloader type and version.
- Partition boundaries.
- Linux kernel or alternative operating system.
- Root filesystem format.
- Compression algorithms.
- Startup services.
- Watchdog configuration.
- Camera sensor drivers.
- LCD drivers.
- Wi-Fi stack.
- Power management.
- GPIO assignments.
- Application architecture.
- OTA update implementation.

### Example Commands
```bash
file firmware.bin
binwalk firmware.bin
strings firmware.bin
xxd -l 256 firmware.bin
```

## Phase D — Hardware Compatibility Investigation

### Goal
Research OpenIPC compatibility only after the exact SoC is confirmed.

### References
- https://openipc.org/
- https://github.com/OpenIPC/firmware
- https://github.com/OpenIPC/wiki
- https://buildroot.org/

## Phase E — Custom Firmware Implementation

### Milestones
1. Controlled boot into a reproducible custom environment.
2. Basic hardware initialization and debug console.
3. Working camera sensor and video encoding.
4. Wi-Fi connectivity and a local API.
5. RTSP or equivalent local streaming.
6. MQTT events and Home Assistant integration.
7. LCD display and physical buttons.
8. Battery monitoring and low-power operation.
9. Reliable startup, recovery, and firmware update procedure.

## Technical Roadmap

1. Phase A: Serial diagnostics
2. Phase B: Flash backup
3. Phase C: Firmware analysis
4. Phase D: Hardware compatibility investigation
5. Phase E: Custom firmware development
6. Phase F: Home Assistant integration

## Evidence Checklist

- [ ] UART serial logs capture
- [ ] Verified SPI flash backup
- [ ] Complete firmware analysis
- [ ] Hardware inventory documented
- [ ] OpenIPC compatibility confirmed or ruled out
- [ ] Recovery procedures validated