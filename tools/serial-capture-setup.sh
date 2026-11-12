#!/bin/bash

# RH-PD10 UART Serial Capture Setup Script
# Configures serial terminal for passive UART logging from camera

echo "=== Setting up UART serial capture ==="

# Check if required tools are installed
if ! command -v picocom &> /dev/null; then
    echo "Error: picocom not found. Install with: brew install picocom"
    exit 1
fi

# Show available serial devices
echo "Available serial devices:"
ls /dev/cu.*

echo ""
echo "Please identify your USB-to-serial adapter device from above."
echo "The device will typically be named something like /dev/cu.usbserial-XXXX"
echo ""

# Example usage instructions
echo "Example command to start capture:"
echo "picocom -b 115200 /dev/cu.usbserial-XXXX"
echo ""
echo "To stop, press Ctrl+A then Ctrl+Q"