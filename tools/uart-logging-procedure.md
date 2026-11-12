# UART Logging Procedure - RH-PD10

## Overview
This document details the procedure for passive UART logging during boot sequence to capture device initialization and potential error conditions.

## Safety Requirements
Before starting UART logging:
1. **Verify Signal Levels**: Confirm 1.8V logic levels on all UART test pads
2. **Proper Connection**: Connect RXD to adapter TXD, TXD to adapter RXD
3. **Ground Connection**: Ensure common ground between device and adapter
4. **Avoid Driving Signals**: Do not connect adapter TXD until signal levels verified

## Hardware Connection Setup
1. Identify UART test pads on PCB:
   - Upper group: RXD, TXD, GND
   - Lower group: GND, 1.8V, TXD, RXD

2. Connect adapter as follows:
   ```
   Device Pad → Adapter Pin
   RXD        → TXD (transmit)
   TXD        → RXD (receive) 
   GND        → GND (ground)
   ```

## Logging Setup Script
```bash
#!/bin/bash
# uart-logging.sh

BAUD_RATE=115200
DEVICE_PORT="/dev/ttyUSB0"  # Change to your actual port

echo "Starting UART logging..."
echo "Press Ctrl+A then Ctrl+Q to exit picocom"

picocom -b $BAUD_RATE $DEVICE_PORT
```

## Capture Process
1. **Prepare Device**:
   ```bash
   # Connect battery and USB power briefly to boot device
   # Then disconnect all power sources and reconnect only adapter
   ```

2. **Start Logging Session**:
   ```bash
   chmod +x uart-logging.sh
   ./uart-logging.sh
   ```

3. **Reboot Device**:
   ```bash
   # Reconnect battery briefly to trigger boot process
   # The device should boot and output information to UART
   ```

4. **Save Capture**:
   - When capture complete, press `Ctrl+A`, then `Ctrl+Q` 
   - Log will be automatically saved by picocom in the session log directory

## Analysis Preparation
1. Save logs with descriptive names: 
   ```bash
   mv /tmp/picocom.log boot_sequence_YYYY-MM-DD.log
   ```

2. Analyze content for:
   - Bootloader type and version
   - Kernel messages and versions  
   - Error messages or warnings during initialization
   - Storage map information
   - Any reset cause indicators

## Tools for Analysis
```bash
# Quick analysis of captured logs
grep -i "error\|fail\|reset" boot_sequence.log

# Extract specific patterns from logs
strings boot_sequence.log | grep -E "(gk7202|kernel|boot)"

# Search for common device identifiers
strings boot_sequence.log | grep -E "(RH-PD10|CRG300)"
```

## Expected Output Content
Typical UART output should contain:
- Device identification (model name, board ID)
- Bootloader information
- Linux kernel version and initialization messages  
- Memory map allocation
- Hardware component detection
- Any error indicators or boot failures

## Troubleshooting
1. **No Output**: Check connections, verify signal levels with multimeter
2. **Garbled Characters**: Verify baud rate (start with 115200)
3. **Connection Issues**: Recheck grounding and wire routing
4. **Timeout Errors**: Confirm adapter is properly detected by system