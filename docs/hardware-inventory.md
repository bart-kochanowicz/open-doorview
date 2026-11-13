# Hardware inventory

This inventory preserves leads from the initial project notes. They have not been independently verified in this repository. Treat markings, measurements and ratings as reported until supported by photos, measurements, datasheets or logs.

| Item | Initial report | Status / next evidence |
| --- | --- | --- |
| Device | RH-PD10 smart door peephole camera | Confirm label and document symptoms. |
| Main board | Marking `CRG300-MAIN-V3.1` | Verify against a clear photo. |
| SoC | GOKE GK7202 suspected | Exact marking and manufacturer unconfirmed; do not assume compatibility. |
| Flash | Winbond `W25Q64JWSSIQ`, reportedly 64 Mbit / 8 MiB | Confirm the complete physical marking, package, datasheet and programmer identification before use. |
| Battery | Li-ion, reportedly 3.7 V nominal / 5000 mAh | Verify label and connector. |
| UART pad groups | Labels reported as RXD, TXD, GND and 1.8V | Physical location, signal direction and relationship to the main SoC unverified. See [UART diagnostics](uart-pinout.md). |
| Measurements | 1.8V pad and idle TXD reported around 1.8 V; RXD around 0 V | Source, measurement conditions and pad group are not recorded; remeasure. These values do not establish tolerance of any other pin. |
| Camera, display, Wi-Fi, buttons | Present or expected from initial notes | Identify the individual components and interfaces. |

## Evidence to collect

- Clear board and component photos, including full chip markings and orientation.
- Battery label and power connector details.
- Voltage measurements with ground reference, power state, meter settings and pad locations recorded.
- Complete UART boot log and an independently verified flash backup, kept privately.
- Model and configuration of the UART adapter, programmer, level shifter and clip.

Do not infer a pin's voltage tolerance or a component's interface from its appearance. Update this table with a source and confidence level when new evidence is available.
