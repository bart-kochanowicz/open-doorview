# RH-PD10 Firmware Recovery Project - Usage Guide

## Quick Start

1. **Setup the environment:**
   ```bash
   make setup
   ```

2. **Check that all required tools are installed:**
   ```bash
   make check-tools
   ```

3. **Install missing tools (macOS):**
   ```bash
   make install-tools
   ```

## Workflow Steps

### Step 1: Discover Serial Ports
```bash
make discover-ports
```

### Step 2: Start UART Logging (Manual)
```bash
make uart-logs
```
> Then connect your USB-to-serial adapter and run:
> ```bash
> picocom -b 115200 /dev/cu.usbserial-XXXX
> ```

### Step 3: Backup Flash Memory
```bash
make backup-flash
```
> **Important:** Ensure you've disconnected battery and USB power before proceeding. Read safety rules in AGENTS.md.

### Step 4: Analyze Firmware
```bash
make analyze-firmware
```

## Project Structure

```
.
├── Makefile                # Main project automation
├── USAGE.md               # This file
├── AGENTS.md              # Safety rules and procedures
├── README.md              # Project overview  
├── docs/                  # Documentation
│   ├── hardware-inventory.md
│   └── uart-pinout.md
├── tools/                 # Automation scripts (empty - managed by Makefile)
├── backups/               # Backup storage (created by setup)
├── logs/                  # Log storage (created by setup)
└── firmware/              # Custom firmware development
```

## Safety Reminder

Before any hardware interaction:
1. **Read AGENTS.md** completely - it contains the essential safety rules
2. **Disconnect battery and USB power** from device  
3. **Verify CH341A adapter voltage levels** are set to 1.8V
4. **Verify chip orientation** - confirm SOP-8 package orientation

## Troubleshooting

### If tools are missing:
```bash
make install-tools  # macOS only
```

### If serial port discovery fails:
```bash
# On macOS, you might need to use: /dev/tty.usbserial-XXXX instead of /dev/cu.usbserial-XXXX
ls -la /dev/tty.*
```