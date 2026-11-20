# Troubleshooting

Everything here comes from problems actually met on the development unit. If yours differs, capture the UART boot log (passively first) before changing anything.

Useful commands on the camera (UART shell):

```sh
uptime; cat /proc/uptime
dmesg | grep -E 'syslink_sdio|doorview' | tail -30
dmesg | grep 'FIFO empty' | tail -1        # frames, ethernet, tx, errors counters
ifconfig dv0
cat /tmp/doorview-lcd-boot.log; cat /tmp/lcd-vo-test/button-listener.log
cat /tmp/doorview-mqtt.log
```

## Wi-Fi

**The camera does not answer on the network after boot, but the UART works.**
Look at `dmesg | grep 'FIFO empty'`:

- `ethernet=` stays at a small number (for example 4) and never grows, `ping` of the gateway from the camera fails: the Wi-Fi coprocessor is in a state it will not leave without losing power. **Disconnect all power** (USB and battery, a few seconds), reconnect, and let it boot. A soft `reboot` does not reset it. Repeating station commands (`reconnect`, stop/start/connect) made this worse in testing.
- `FIFO empty` grows by about 100 per second and `frames` is frozen: this is the polling-driver stall. The stage 2 interrupt-driven driver exists to avoid it. If it happens with stage 2 installed, check `ls /sys/module/syslink_net/parameters/` for `irq_rx`, `rx_gpio`, `rx_poll_ms`: if they are missing, the polling driver was loaded (the interrupt driver failed to start; `dmesg` says why).
- `station.hex` wrong (typo in the passphrase, SSID or passphrase with more than 31 bytes): the camera never joins. Recreate it with `make-wifi-config.py` and `configure.sh --replace`.

**Joined, but only some hosts can reach it.** Early drivers did not always receive ARP requests from other hosts (the gateway's got through). In testing, a directed ARP request sent *from* the camera to the client populated both neighbour caches and restored access; that was a diagnostic helper and is not shipped. The cause was never found. Prefer a static reservation on a normal, non-isolated network, and test from a second client.

**The stream stutters or is far slower than real time.** Use the 640×360, 5 fps, 128 kb/s profile from the install guide and make sure `isp.slowShutter` is `disabled` (in a dark room the sensor otherwise drops to 2 fps). The SDIO link carries only a few hundred kilobits per second of useful video.

**`dmesg` shows `syslink_poll: valid=0` and the SDIO device never appears.** The MCU did not answer the wake-up frame. `S39doorview` retries ten times. Power-cycle the camera. If it persists, capture the UART passively during boot.

**The console goes silent.** A normal press of the camera's power button recovered it after the one command that is known to cause this (an MCU-heartbeat experiment that is **not** part of any shipped file). Capture passively and do not send anything to the MCU.

**The camera reboots by itself early in boot, before `S41`.** Seen on both drivers, with no recorded cause (the kernel initialises a watchdog; nothing proves it is the culprit). A second boot normally succeeds. Record the whole boot log if you see it: it is an open question.

## LCD and button

**Nothing happens when the button is pressed.**

1. Wait at least 20 s after boot: `S96doorview-lcd` starts the service 20 s late, in the background.
2. `cat /tmp/lcd-vo-test/button-listener.log` must contain `BUTTON_PREVIEW_READY`.
3. Press the button and run `dmesg | grep command=a5`. No `command=a5` lines means the MCU messages are not arriving: that is the Wi-Fi/SDIO stall above (check `FIFO empty`).
4. `cat /tmp/lcd-vo-test/button-preview-last.log` shows the last preview run.

**The panel stays dark, but the listener started a preview.** `live-30.sh` refuses to touch the pin mux if a register does not hold the value it expects ("Unexpected pinmux state at ..."): your board or image differs, so do not force it, and read [lcd-and-button.md](lcd-and-button.md#pin-mux). `cat /tmp/lcd-vo-test/live-vo.log` and `head /proc/umap/vo` show whether the VO unit received frames.

**Colours are wrong or the picture is shifted.** The shipped path was verified by eye on one panel only.

## Installers

Every installer prints nothing and exits non-zero when it refuses. Run it as `sh -x install.sh <dir> 2>&1 | tail` to see which check failed. The usual reasons:

| Refusal | Meaning |
|---|---|
| mount check | `/` is not an overlay, `/overlay` is not `/dev/mtdblock5` as jffs2, or `/etc`, `/etc/doorview`, `/etc/init.d` is masked by another mount. A different image layout |
| stage file / `SHA256SUMS` | the upload was damaged, or a file was edited |
| target already exists | the stage is already installed, or you created the file yourself. Installers never overwrite |
| exact old hash | stages 2 and 3 only: the file they replace is not the tested one |
| free space | the overlay has less than the stage needs (100 KB for stages 1 and 3, 300 KB for stage 2). Remove files you added, or stop: it is a 704 KB partition |

A failure after the first file is written rolls the tree back by itself. If the camera loses power during an install, check `/etc/doorview`, `/etc/init.d` and the hidden `.wifi-install.*`, `.mqtt-install.*` and `.restore.*` files, restore from your overlay backup if anything is unclear, and re-run.

## Reading a failed upload

`upload-archive.py` verifies the archive's SHA-256 on the camera before unpacking it. A timeout usually means the console was busy (another reader on the serial port: only one program may use it at a time) or the login prompt did not match. Check the serial device and that no terminal program is attached.
