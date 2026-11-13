# Open Doorview

An evidence-driven project to diagnose, preserve and eventually develop custom firmware for an RH-PD10 smart door peephole camera. The long-term goal is local operation and Home Assistant integration, subject to what the hardware supports.

## Current status

The repository starts with working hypotheses, not verified findings. No boot log, verified flash backup, partition map, recovery method or firmware compatibility result is recorded here yet. The precise SoC, UART pinout and electrical characteristics must be confirmed on the actual board.

Start with [the hardware inventory](docs/hardware-inventory.md) and [passive UART diagnostics](docs/uart-pinout.md). Record observations and their sources as work progresses. The operating and approval rules for agents are in [AGENTS.md](AGENTS.md).

## Workflow

1. **Diagnose:** identify the board and capture a complete boot cycle through passive UART.
2. **Preserve:** identify the flash and obtain two matching, complete reads before considering modifications.
3. **Analyze:** work on copies of the backup and document findings, including the actual [flash layout](docs/flash-layout.md).
4. **Investigate compatibility:** confirm the exact SoC and supporting hardware before evaluating OpenIPC or other platforms.
5. **Develop and integrate:** establish a recoverable boot path, then investigate camera, networking, local streaming, Home Assistant, display and power management.

Each stage depends on evidence from the previous stages. A matching backup alone does not prove that restoration works; recovery must be validated separately.

## Safety and privacy

- Never erase or write flash, modify the bootloader environment, or perform another potentially irreversible hardware operation without explicit approval immediately beforehand. Never overwrite original flash before a complete, verified backup exists.
- Validate the voltage, wiring and chip orientation before connecting a programmer. Disconnect the camera battery and USB power during external SPI programming. Do not connect independent power sources to the same rail.
- Begin UART capture with camera TX → adapter RX and common ground only. Validate levels before connecting adapter TX; do not use the UART supply pad to power the device.
- Original dumps and serial logs can contain credentials, tokens and device identifiers. Store them privately outside the repository, keep secure copies, and sanitize excerpts before sharing. The ignore rules are a precaution, not a guarantee against disclosure.
- Do not assume compatibility from a suspected SoC or flash an image merely because it looks similar.

See [AGENTS.md](AGENTS.md) for the complete operating rules and the [backup procedure](docs/flash-layout.md#backup-procedure) for prerequisites.
