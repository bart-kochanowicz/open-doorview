# Hardware Inventory - RH-PD10 Smart Door Peephole

## Device Overview
- **Model**: RH-PD10 smart door peephole camera
- **PCB Marking**: CRG300-MAIN-V3.1
- **Main Processor**: GOKE GK7202 (suspected)
- **SPI NOR Flash**: Winbond W25Q64JWSSIQ (8 MiB)
- **Power Source**: Li-ion battery, nominal 3.7 V, 5000 mAh

## Chip Details

### Main SoC
- **Manufacturer**: GOKE
- **Suspected Family**: GK7202
- **Exact Model**: NOT YET CONFIRMED
- **Package Type**: Likely QFN or BGA
- **Operating Voltage**: Unknown, but likely 1.8 V logic with some 3.3 V tolerant pins

### SPI Flash Memory
- **Manufacturer**: Winbond
- **Model**: W25Q64JWSSIQ
- **Capacity**: 64 Mbit / 8 MiB
- **Operating Voltage**: 1.7–1.95 V
- **Interface**: SPI / Dual SPI / Quad SPI
- **Package**: SOP-8, 208 mil

## Physical Components

### Display
- Integrated LCD display
- Resolution and interface type unknown
- Likely connected via MIPI or parallel interface

### Camera Module
- External camera module connected through flex cable
- Sensor type and specifications unknown
- ISP availability uncertain

### Connectivity
- Wi-Fi connectivity (likely 2.4 GHz)
- Speaker
- Physical controls/buttons

### Power Management
- Li-ion battery charging circuitry
- PMIC (Power Management IC) 
- Battery monitoring capabilities
- Voltage regulation for multiple rails

## Serial Interfaces

### UART Test Pads
- **Upper group**: RXD, TXD, GND (possibly 1.8V)
- **Lower group**: GND, 1.8V, TXD, RXD (possibly 1.8V)

### Measured Values
- 1.8V pad: approximately 1.8 V
- TXD: approximately 1.8 V when idle
- RXD: approximately 0 V in earlier measurement

## Electrical Specifications and Constraints

### Signal Levels
- Confirmed 1.8V logic levels on multiple pads
- Need to verify which components use 3.3V tolerant inputs

### Power Rails
- Li-ion battery supply (nominal 3.7 V)
- 1.8 V system power rail
- Potential 3.3 V rails for peripherals

## Known Unknowns and Research Tasks

### Unidentified Elements
- Exact SoC model number
- Camera sensor specifications (type, resolution, interface)
- LCD controller chip details
- RAM chip model and capacity
- Wi-Fi chipset model
- PMIC model and specifications
- GPIO mapping and function assignments

### Documentation Requirements
1. Complete pinout for main SoC
2. Detailed datasheets for all identified chips
3. Boot process and memory map
4. Clock and power distribution
5. Hardware initialization sequence

## Measurement Plan

1. Confirm UART connections using multimeter
2. Verify voltage levels with oscilloscope if available
3. Map GPIO functions through firmware analysis
4. Test component accessibility via I2C/SPI buses if possible
5. Document all physical connections and components

This inventory forms the foundation for subsequent phases of analysis and recovery.