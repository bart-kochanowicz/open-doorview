# LCD panel and front button

OpenIPC for the GK7202V300 has no framebuffer and no input device for this board. The panel is driven directly through the SoC's video-output (VO) unit with the vendor driver that OpenIPC ships for the sibling GK7205V200, and the button is read from the MCU's `0xA5` messages ([coprocessor](wifi-companion.md)). Everything here is **observed on one unit**; items that are guesses are marked.

## The panel

| Item | Value | Evidence |
|---|---|---|
| Size and format | 480 × 272, NV21 (YUV 4:2:0) | observed |
| Interface | `LCD_8BIT` (`0x400`), user-defined sync, progressive | from the factory firmware; output verified on the panel |
| Timing | horizontal back porch 65, front porch 7, pulse 1; vertical back porch 15, front porch 9, pulse 1; 30 fps | from the factory firmware; output verified |
| Clock | `LCDMCLK`, pre-divider 1, device divider 3 (divider field `0x001ef73d`) | from the factory firmware; accepted by the driver |
| FPC marking | `4306J40R09-L`, `40` end mark | photo |
| Controller, FPC pinout, voltages | **unknown**. No datasheet was found. The factory start-up shows no separate command channel, only the VO data lines plus the enable GPIO | not established |

The panel is enabled by the factory "LcdEn" pin, **GPIO15 in the factory's decimal bank/pin notation = GPIO1_5 = Linux GPIO 13**, active high. The SDK uses the same pad for an audio amplifier unmute on other boards; its role on this camera beyond the panel enable is unverified.

## Pin mux

The panel data pads are 12 registers in the VIO I/O block at `0x112c0000`. Factory start-up writes these values (observed in the RTOS start-up code):

| Offset | Factory value | OpenIPC default (guard value) |
|---|---|---|
| `0x48`, `0x6c` | `0x1a05` | `0x1a30`, `0x1a00` |
| `0x4c`, `0x50`, `0x54`, `0x58`, `0x5c`, `0x60`, `0x64`, `0x68`, `0x70`, `0x74` | `0x1005` | `0x1120`, `0x1000`, `0x1a00`, `0x1120` (x4), `0x1000`, `0x1000`, `0x1000` |

`live-30.sh` reads each register first and **refuses to run if any value differs from the OpenIPC default it expects**, so it cannot overwrite a pin that a different configuration uses (offsets `0x58` and `0x5c` can be the sensor's I²C on other boards). It saves the values, writes the factory ones, and restores the saved values when it ends or fails.

## How the preview works

1. `S96doorview-lcd` starts, 20 s after boot and in the background, `/etc/doorview-lcd/service`. The service copies its files to `/tmp/lcd-vo-test` (do not delete or reuse that directory while the camera runs: the preview is started from it), loads `vo.ko` (the vendor VO driver) if `/dev/vo` is missing, and starts `button-preview`.
2. `button-preview` (`firmware/userland/lcd/button-preview.c`, freestanding, no libc) follows `/dev/kmsg` and waits for `doorview_control: command=a5 length=8`. One press produces a burst of records; records less than 250 ms apart count as one press. It seeks to the end of the log first, so history from before it started is ignored, and presses while a preview is running are ignored (the preview is not extended).
3. On a press it runs `live-30.sh`, which holds a lock so a second press cannot start a second preview, switches the pin mux (above), starts `vo-live-30`, checks `/proc/umap/vo` shows frames received and displayed, and only then raises the backlight (GPIO 13). After about 30 s it lowers the backlight and restores the pin mux.
4. `vo-live-30` (`firmware/userland/lcd/vo-live-30.c`) takes **VPSS channel 2** (the camera's spare scaler output, 480 × 272 NV21 at about 5 fps; channel 0 rejects the LCD size because the online-mode scaler requires the input size), copies each frame into a private VO buffer pool and releases the VPSS frame at once, so the RTSP pipeline keeps running. It only touches that channel and the VO unit.

Safety guards in the service: it refuses to start unless the backlight pad's mux register (`0x120c0014`) reads the expected `0x00001E02`, and after raising the backlight it checks GPIO1's data register (`0x120b1080`) shows bit 5 set.

The vendor libraries need a small ABI shim, `libuclibc-compat.so` (OpenIPC's `uclibc-compat` package, MIT licence), and the SDK libraries are preloaded: `LD_PRELOAD="./libuclibc-compat.so /usr/lib/libsecurec.so /usr/lib/libvoice_engine.so /usr/lib/libupvqe.so /usr/lib/libdnvqe.so"`.

## Colour

The panel shows BT.601 YUV through the VO unit. Feeding RGB data needed a BT.601-to-RGB colour matrix to get correct colours; the shipped preview feeds NV21 directly and was verified visually on one panel.

## Why stage 2 also replaces the SDIO driver

The button only works while the SDIO link delivers the MCU's messages. The polling driver stopped delivering them at random times, so the button appeared dead. The interrupt-driven driver does not show this, which is why the LCD stage ships it. See [wifi-companion](wifi-companion.md#why-the-interrupt-driven-driver-is-the-shipped-one).

## Porting notes

Only the pin-mux table, the panel timing and the GPIO number above are board-specific. The factory panel-enable pin is GPIO1_5, **Linux GPIO 13** (the factory notation "GPIO15" is decimal bank/pin, not a Linux number). Any new test of the panel must read the pin-mux registers first and save and restore them, as `live-30.sh` does. The panel controller and FPC pinout are not known, so nothing beyond the VO data path should be attempted without that evidence.

## Open items

- Panel controller and FPC pinout (needed for anything beyond the VO data path).
- Whether a lower backlight level is possible (the shipped service only switches it on and off).
- The LCD stays off when Linux is not running; nothing shows during boot.
