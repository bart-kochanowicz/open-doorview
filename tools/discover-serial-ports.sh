#!/bin/bash

# RH-PD10 Serial Port Discovery Script
# Identifies and verifies available serial ports for UART debugging

echo "=== RH-PD10 Serial Port Discovery ==="
echo ""

# Check for available serial devices
echo "Looking for serial devices..."
if ls /dev/cu.* 1> /dev/null 2>&1; then
    echo "Found serial devices:"
    ls -la /dev/cu.*
    echo ""
else
    echo "No serial devices found in /dev/cu.*"
    echo ""
fi

# Check for common USB-to-serial adapters
echo "Checking for common USB-to-serial adapter types..."
if command -v lsusb &> /dev/null; then
    echo "USB devices:"
    lsusb | grep -i -E "(serial|usb|chip)"
else
    echo "lsusb command not available"
fi

# Check if picocom is available for terminal communication
echo ""
echo "Checking required tools..."
if command -v picocom &> /dev/null; then
    echo "✓ picocom (UART terminal) - available"
else
    echo "✗ picocom - NOT available (install with: brew install picocom)"
fi

# Display detailed information about the system
echo ""
echo "=== System Information ==="
uname -a

echo ""
echo "=== Next Steps ==="
echo "1. Identify your USB-to-serial adapter from the list above"
echo "2. Connect the adapter to the camera UART test pads as described in docs/uart-pinout.md"
echo "3. Run: picocom -b 115200 /dev/cu.usbserial-XXXX (replace XXXX with your device ID)"