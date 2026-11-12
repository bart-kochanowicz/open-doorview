# UART Pinout - RH-PD10 Smart Door Peephole

## Overview
This document details the UART connections for the RH-PD10 device based on physical identification and measurement.

## Identified UART Test Pads

### Upper Group
- RXD (Receive Data)
- TXD (Transmit Data)
- GND (Ground)

### Lower Group
- GND (Ground)
- 1.8V (Supply Voltage)
- TXD (Transmit Data)
- RXD (Receive Data)

## Signal Levels
- 1.8V pad: Approximately 1.8 V
- TXD pad: Approximately 1.8 V when idle
- RXD pad: Approximately 0 V in earlier measurement

## Connections Diagram
```
            Camera PCB
        ┌─────────────┐
        │   Upper     │
        │   Group     │
        │ [RXD][TXD]  │
        │   [GND]     │
        └─────────────┘
                 │
              UART
                 │
        ┌─────────────┐
        │   Lower     │
        │   Group     │
        │ [GND][1.8V] │
        │ [TXD][RXD]  │
        └─────────────┘
```

## Connection Recommendations
1. Connect device RXD to adapter TXD (transmit)
2. Connect device TXD to adapter RXD (receive)
3. Connect both GND pins together
4. The 1.8V pin can be used for power supply if needed, but use with caution

## Baud Rate Settings
- Default rate: 115200 8N1 (115200 baud, 8 data bits, no parity, 1 stop bit)

This configuration allows passive capture of the boot sequence without driving signals from the adapter.