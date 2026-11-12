# RH-PD10 Smart Door Peephole Camera Recovery & Custom Firmware

This repository contains documentation, tools, and procedures for recovering and developing custom firmware for the RH-PD10 smart door peephole camera.

## Project Overview

The RH-PD10 is a smart door peephole camera that has encountered boot issues. This project documents the process of:
- Identifying root cause of boot problems
- Creating verified backups of original firmware
- Reverse engineering existing system architecture
- Developing safe, enhanced custom firmware solutions

## Hardware Specifications

- **Device**: RH-PD10 smart door peephole camera
- **Main Processor**: GOKE GK7202 (suspected) 
- **SPI Flash**: Winbond W25Q64JWSSIQ (8 MiB / 64 Mbit)
- **Operating Voltage**: ~1.8V logic levels

## Safety Rules

⚠️ **CRITICAL SAFETY REQUIREMENTS** - These are non-negotiable:

1. **Never erase or overwrite original flash** before obtaining and verifying a complete backup
2. **Never connect 3.3 V or 5 V signals** directly to confirmed 1.8 V logic 
3. **Verify CH341A adapter settings** (1.8V operation) and wiring
4. **Disconnect battery and USB power** before external SPI programming  
5. **Never connect two independent power sources** to the same rail without verified design
6. **Use passive UART reception initially**: device TX to adapter RX, + common GND
7. **Do not execute destructive flash commands automatically**
8. **Ask for explicit approval** before any erase/write operations

Refer to AGENTS.md for full safety guidelines.

## Project Structure

```
.
├── README.md              # This file - project overview
├── AGENTS.md              # Safety rules and procedures
├── Makefile               # Main automation workflow 
├── USAGE.md               # How to use the Makefile targets
├── docs/                  # Documentation
│   ├── hardware-inventory.md  # Hardware specs and components
│   └── uart-pinout.md         # UART connections and pinout
├── backups/               # Flash backup storage (created by setup)
├── logs/                  # Serial logging output (created by setup)
└── tools/                 # Automation scripts (managed by Makefile)
```

## Recovery Workflow Phases

### Phase A: Diagnostics 
- Identify boot issues and reset causes
- Establish UART communication 
- Document device behavior and bootloader information

### Phase B: Backup
- Create verified SPI flash backup 
- Analyze partition layout and storage map
- Examine bootloader, kernel version, and OS  

### Phase C: Analysis
- Fully analyze firmware architecture  
- Identify drivers, sensors, interfaces
- Document hardware configuration

### Phase D: Custom Firmware Development
- Implement base system (OpenIPC, Buildroot, etc.)
- Add camera functionality and video encoding  
- Enable Wi-Fi, MQTT, and Home Assistant integration
- Add LCD display and button support 

## Getting Started

1. **Review safety rules** in AGENTS.md
2. **Setup environment**: `make setup`
3. **Verify tools**: `make check-tools` 
4. **Follow phases A-D** sequentially for recovery workflow

Run `make help` to see all available commands.