# Passive UART diagnostics

## Status

The initial notes mention two groups of pads labelled `RXD`, `TXD`, `GND`, and, on one group, `1.8V`. Their physical arrangement, connection to the main SoC and signal levels are **not verified in this repository**. A prior report of approximately 1.8 V on an idle TXD pad has no recorded measurement conditions. Do not use an assumed diagram as a pinout.

## Preparation

1. Photograph the board and label each pad and its group. Identify ground and measure the suspected TX pad relative to ground while the camera is powered, recording the conditions and results. Avoid shorting adjacent pads.
2. Identify the Waveshare USB–UART adapter and verify its documentation, VCCIO configuration and actual RX input compatibility with the measured device signal. Do not assume that a jumper label proves the voltage. Do not connect 3.3 V or 5 V signals to 1.8 V logic.
3. Connect **camera TX → adapter RX**, and camera GND → adapter GND. Leave adapter TX and the camera's 1.8 V pad disconnected. Do not power the camera from the adapter.
4. Power the camera normally for UART diagnostics. External SPI programming has different power requirements: disconnect both its battery and USB first.

## Capture on macOS

Compare ports before and after connecting the adapter:

```sh
ls /dev/cu.*
```

Open the verified adapter port, initially trying 115200 baud, 8 data bits, no parity and one stop bit:

```sh
picocom -b 115200 /dev/cu.usbserial-XXXX
```

Replace the example with the actual port. Configure terminal logging to a private location before rebooting the camera; capture from before power-on through the complete boot or reset cycle. Exit picocom with `Ctrl-A`, then `Ctrl-X`. Record the port, settings, power state and pad group. If output is garbled or absent, recheck ground, RX connection, voltage compatibility and baud rate; silence alone does not establish a pinout or a fault.

Keep raw logs private: they may contain device identifiers and secrets. Review and redact excerpts before sharing. Do not connect adapter TX until its output voltage has been validated; any active interaction must follow the approval rules in [AGENTS.md](../AGENTS.md).
