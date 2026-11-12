# RH-PD10 Smart Door Peephole Camera Recovery & Custom Firmware

This repository contains documentation, tools, and procedures for the recovery and custom firmware development of the RH-PD10 smart door peephole camera.

## Project Structure

```
.
├── README.md
├── AGENTS.md
├── docs/
│   ├── hardware-inventory.md
│   ├── uart-pinout.md
│   ├── boot-analysis.md
│   ├── flash-layout.md
│   ├── firmware-analysis.md
│   ├── recovery-options.md
│   └── roadmap.md
├── tools/
│   ├── serial-capture/
│   ├── flash-backup/
│   └── firmware-analysis/
├── firmware/
│   ├── configs/
│   ├── patches/
│   └── rootfs-overlay/
├── integrations/
│   └── home-assistant/
├── logs/
├── backups/
│   └── README.md
└── .gitignore
```

## Project Objectives

### Phase A — Diagnosis and recovery
Identify the root cause of the existing boot loop, obtain a verified backup of the original SPI flash, and determine whether the device can be restored.

### Phase B — Firmware reverse engineering
Analyze the original firmware architecture, bootloader, partition layout, operating system, drivers, sensor interfaces, power-management logic, and hardware-specific components.

### Phase C — Custom firmware development
Investigate creating an alternative firmware based on OpenIPC, Buildroot, an existing compatible embedded Linux platform, or a custom minimal system.

### Phase D — Home Assistant integration
Create local control capabilities for smart peephole camera supporting:
- Local video streaming (RTSP)
- Local event reporting through MQTT
- Home Assistant integration
- Doorbell-button events
- Battery percentage reporting
- Local LCD preview
- Camera wake-up and sleep management
- Low-power operation
- Local management interface
- No mandatory cloud connection
- Recovery mechanism for failed firmware updates

## Hardware Information

Device: RH-PD10 smart door peephole.
PCB marking previously observed: CRG300-MAIN-V3.1.

Main processor:
- Manufacturer: GOKE.
- Suspected family: GK7202.
- Exact SoC model: NOT YET CONFIRMED.

SPI NOR Flash:
- Manufacturer: Winbond.
- Model identified from photograph: W25Q64JWSSIQ.
- Capacity: 64 Mbit / 8 MiB.
- Operating voltage: 1.7–1.95 V.
- Interface: SPI / Dual SPI / Quad SPI.
- Package: SOP-8, 208 mil.

## Safety Rules

These rules are non-negotiable:
1. Never erase or overwrite original flash before obtaining and verifying a complete backup.
2. Never connect a 3.3 V or 5 V signal directly to confirmed 1.8 V logic.
3. Verify CH341A output voltage, signal voltage, adapter wiring, pin 1 orientation, and chip compatibility before connecting it to flash.
4. Disconnect the device battery and USB power before external SPI programming.
5. Never connect two independent power sources to the same rail without a verified electrical design.
6. Prefer passive UART reception initially: device TX to adapter RX, plus common GND. Do not connect adapter TX until its voltage has been validated.
7. Never flash an OpenIPC image based only on a suspected processor family.
8. Do not overwrite bootloader, calibration, device identity, MAC addresses, or other unique partitions without explicit approval.
9. Do not execute destructive flash commands automatically.
10. Ask for explicit approval immediately before any flash erase/write, bootloader environment modification, or other potentially irreversible hardware operation.
11. Preserve original binary images securely. They may contain Wi-Fi credentials, tokens, or unique device secrets. Do not publish complete dumps to public Git repositories.
12. If in-circuit programming is unreliable, stop and report the risk of bus contention or back-powering. Consider chip removal only as an explicitly approved later option.
