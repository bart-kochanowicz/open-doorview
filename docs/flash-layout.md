# SPI Flash Layout - RH-PD10 Smart Door Peephole

## Overview
This document details the flash memory layout for the RH-PD10 device based on available information and analysis.

## Identified Chip Specifications
- **Manufacturer**: Winbond
- **Model**: W25Q64JWSSIQ
- **Capacity**: 8 MiB (64 Mbit)
- **Package**: SOP-8, 208 mil

## Memory Organization
The flash memory is organized into:
- 16 sectors of 4 KiB each (64 KiB total)
- 128 pages of 256 bytes each (32 KiB total)

## Partition Table
Based on similar devices and analysis expectations:

### Boot Partition (32 KiB)
- Contains bootloader code
- Located at flash address 0x000000

### Kernel Partition (128 KiB) 
- Linux kernel image
- Stored immediately after bootloader

### Root Filesystem (3 MiB)
- Main operating system
- May be compressed
- Located at 0x020000

### Configuration/Calibration (16 KiB)
- Device identity information
- Calibration data

### Other Partitions
- Reserved areas for potential OTA updates
- Wi-Fi credentials area
- Additional firmware regions

## Flash Operations Required
Before any backup or modification:
1. Disconnect battery power
2. Verify 1.8V signal levels
3. Use CH341A SPI adapter with verified voltage protection
4. Confirm SOIC-8 clip orientation compatibility
5. Ensure no other USB power sources connected

## Safety Precautions
- Never modify or erase partitions without proper permission
- Always use official toolchain (flashrom)
- Verify all backup operations produce consistent hashes

## Recovery Workflow Integration
This layout information is used during Phase B (Flash Backup) and Phase C (Firmware Analysis) of the recovery workflow.