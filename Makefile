# RH-PD10 Firmware Recovery Project - Makefile
#
# This Makefile provides organized targets for firmware recovery workflow
# for the RH-PD10 smart door peephole camera.

.PHONY: help setup check-tools install-tools discover-ports serial-setup uart-logs backup-flash analyze-firmware clean

# Default target - show help
help:
	@echo "RH-PD10 Firmware Recovery Project"
	@echo "================================="
	@echo "Available targets:"
	@echo "  setup          - Initialize project environment"
	@echo "  check-tools    - Verify all required tools are installed"
	@echo "  install-tools  - Install missing tools (if on macOS)"
	@echo "  discover-ports - Discover available serial ports"
	@echo "  serial-setup   - Configure serial capture setup"
	@echo "  uart-logs      - Start UART logging session"
	@echo "  backup-flash   - Perform SPI flash backup"
	@echo "  analyze-firmware - Analyze firmware image"
	@echo "  clean          - Clean temporary files"
	@echo ""
	@echo "Usage examples:"
	@echo "  make check-tools"
	@echo "  make discover-ports"
	@echo "  make uart-logs"

# Initialize project environment
setup:
	@echo "Initializing RH-PD10 firmware recovery project..."
	@mkdir -p backups firmware logs integrations backups/verified backups/raw

# Verify all required tools are installed
check-tools:
	@echo "Checking required tools..."
	@which picocom > /dev/null 2>&1 || (echo "Error: picocom not found. Install with: brew install picocom"; exit 1)
	@which flashrom > /dev/null 2>&1 || (echo "Error: flashrom not found. Install with: brew install flashrom"; exit 1)
	@which binwalk > /dev/null 2>&1 || (echo "Error: binwalk not found. Install with: pip3 install binwalk"; exit 1)
	@which strings > /dev/null 2>&1 || (echo "Error: strings utility not found"; exit 1)
	@which sha256sum > /dev/null 2>&1 || (echo "Error: sha256sum utility not found"; exit 1)
	@echo "✓ All required tools are installed"

# Install missing tools (macOS specific)
install-tools:
	@echo "Installing missing tools (macOS)..."
	brew install picocom flashrom binwalk

# Discover available serial ports
discover-ports:
	@echo "Discovering serial ports..."
	./tools/discover-serial-ports.sh

# Configure serial capture setup
serial-setup:
	@echo "Setting up serial capture..."
	./tools/serial-capture-setup.sh

# Start UART logging session (requires prior setup)
uart-logs:
	@echo "Starting UART logging session..."
	@echo "Please connect your USB-to-serial adapter first"
	@echo "Then run: picocom -b 115200 /dev/cu.usbserial-XXXX"
	@echo "Where XXXX is your device identifier from discover-ports"

# Perform SPI flash backup
backup-flash:
	@echo "Starting SPI flash backup procedure..."
	@echo "⚠️ WARNING: Ensure battery and USB power are disconnected!"
	@echo "⚠️ WARNING: Verify CH341A adapter settings for 1.8V operation!"
	@echo "Please confirm you've read safety rules in AGENTS.md"
	@echo ""
	@echo "To proceed with backup:"
	@echo "flashrom -p ch341a_spi -r backups/backup_$(shell date +%Y%m%d_%H%M%S).bin"
	@echo "Verify with: sha256sum backups/backup_*.bin"

# Analyze firmware image
analyze-firmware: check-tools
	@echo "Analyzing firmware image..."
	@echo "Example analysis commands:"
	@echo "file backups/backup_*.bin"
	@echo "binwalk backups/backup_*.bin"
	@echo "strings backups/backup_*.bin | head -20"
	@echo "xxd -l 256 backups/backup_*.bin"

# Clean temporary files
clean:
	@echo "Cleaning temporary files..."
	rm -rf logs/*
	@echo "Clean completed"