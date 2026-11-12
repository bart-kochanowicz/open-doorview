#!/bin/bash

# RH-PD10 Firmware Recovery Tool Installation Script
# Installs all required tools for firmware recovery and analysis

echo "=== RH-PD10 Firmware Recovery Tools Installation ==="
echo ""

# Detect OS type
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
else
    echo "Cannot detect OS type"
    exit 1
fi

echo "Detected OS: $OS $VER"

# Function to install packages based on OS
install_packages() {
    if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
        echo "Installing packages for Debian/Ubuntu..."
        sudo apt update
        sudo apt install -y \
            flashrom \
            picocom \
            binwalk \
            file \
            strings \
            xxd \
            sha256sum \
            python3 \
            build-essential
    elif [[ "$OS" == *"Fedora"* ]] || [[ "$OS" == *"Red Hat"* ]]; then
        echo "Installing packages for Red Hat/Fedora..."
        sudo dnf install -y \
            flashrom \
            picocom \
            binwalk \
            file \
            strings \
            xxd \
            sha256sum \
            python3 \
            gcc \
            make
    elif [[ "$OS" == *"Arch"* ]]; then
        echo "Installing packages for Arch Linux..."
        sudo pacman -Syu --noconfirm \
            flashrom \
            picocom \
            binwalk \
            file \
            strings \
            xxd \
            sha256sum \
            python
    else
        echo "Unsupported OS. Please install the following manually:"
        echo "- flashrom"
        echo "- picocom" 
        echo "- binwalk"
        echo "- file, strings, xxd"
        echo "- sha256sum"
        echo "- python3"
        exit 1
    fi
}

# Install packages
install_packages

echo ""
echo "=== Installation Complete ==="
echo "The following tools are now available:"
echo "- flashrom: SPI flash programming"
echo "- picocom: UART terminal"
echo "- binwalk: Firmware analysis"
echo "- file, strings, xxd: Binary analysis tools"
echo "- sha256sum: Backup verification"
echo "- python3: Scripting support"

echo ""
echo "=== Verification ==="
echo "Checking installed tools:"
command -v flashrom && echo "✓ flashrom installed"
command -v picocom && echo "✓ picocom installed"
command -v binwalk && echo "✓ binwalk installed"
command -v file && echo "✓ file command installed"
command -v strings && echo "✓ strings command installed"
command -v xxd && echo "✓ xxd command installed"
command -v sha256sum && echo "✓ SHA-256 checksum utility installed"
command -v python3 && echo "✓ Python 3 installed"

echo ""
echo "=== Next Steps ==="
echo "1. To list serial ports: ls /dev/ttyUSB* or ls /dev/ttyACM*"
echo "2. To start UART captures: picocom -b 115200 /dev/ttyUSB0 (replace with your port)"
echo "3. For flash backup: flashrom -p ch341a_spi -r backup.bin"