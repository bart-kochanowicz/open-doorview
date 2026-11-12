#!/bin/bash

# RH-PD10 Toolchain Verification Script
# Verifies required tools for firmware recovery and analysis

echo "=== RH-PD10 Firmware Recovery Toolchain Check ==="
echo ""

# Check for required packages via Homebrew
echo "Checking for required packages..."

# Check for picocom (UART terminal)
if command -v picocom &> /dev/null; then
    echo "✓ picocom installed"
else
    echo "✗ picocom not found - install with: brew install picocom"
fi

# Check for flashrom (SPI flash programmer)
if command -v flashrom &> /dev/null; then
    echo "✓ flashrom installed"
else
    echo "✗ flashrom not found - install with: brew install flashrom"
fi

# Check for binwalk (firmware analysis)
if command -v binwalk &> /dev/null; then
    echo "✓ binwalk installed"
else
    echo "✗ binwalk not found - install with: brew install binwalk"
fi

# Check for file command
if command -v file &> /dev/null; then
    echo "✓ file command installed"
else
    echo "✗ file command not found"
fi

# Check for strings command
if command -v strings &> /dev/null; then
    echo "✓ strings command installed"
else
    echo "✗ strings command not found"
fi

# Check for xxd command
if command -v xxd &> /dev/null; then
    echo "✓ xxd command installed"
else
    echo "✗ xxd command not found"
fi

# Check for sha256sum/shasum
if command -v shasum &> /dev/null; then
    echo "✓ shasum (SHA-256) available"
elif command -v sha256sum &> /dev/null; then
    echo "✓ sha256sum (SHA-256) available"
else
    echo "✗ No SHA-256 tool found"
fi

# Check for Python
if command -v python3 &> /dev/null; then
    echo "✓ Python 3 installed"
else
    echo "✗ Python 3 not found - install with: brew install python"
fi

# Check for serial device access
echo ""
echo "Checking available serial devices..."
ls /dev/cu.* 2>/dev/null || echo "No serial devices found"

echo ""
echo "=== Toolchain Check Complete ==="
echo "Recommended: Install missing packages with Homebrew commands above"