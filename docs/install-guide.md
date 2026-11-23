# Install guide: OpenIPC with Wi-Fi, LCD button and MQTT on the RH-PD10

This guide takes an RH-PD10 from its factory firmware to the state this repository was developed on: OpenIPC with Wi-Fi, an RTSP/HTTP stream, a front button that lights the LCD with a live preview, and battery/USB/button state published over MQTT for Home Assistant.

Read [Before you start](#before-you-start) completely. **Flashing replaces the factory firmware. You cannot return to it without your own backup**, and the factory flash holds data that is unique to your unit (MAC address, device identity, cloud keys).

## What you get, and how well it is verified

| Stage | Result | Evidence |
|---|---|---|
| OpenIPC boot | Linux 4.9.37 from flash, Majestic serving HTTP and RTSP | Boot logs; running for days on one unit |
| 1. Wi-Fi base | Station mode on the Wi-Fi coprocessor, static IPv4, `dv0` interface | Installed on one unit; stream decoded for 300 s at 5.03 fps; the installer for this repository was written afterwards and is tested only on fixture trees |
| 2. LCD + button | Front button lights the panel with a 30 s live preview; IRQ-driven SDIO receive | Installed on one unit; four of four button tests, cold start with the battery disconnected |
| 3. MQTT | Battery, external power, button event and uptime for Home Assistant | Installed on one unit; connects to a broker with authentication; observed for minutes and two reboots |

One camera was used throughout. Other units, batches or firmware revisions are untested. See [known limits](known-limits.md) before relying on any of it.

## Before you start

- **Safety rules.** [AGENTS.md](../AGENTS.md) and the [README](../README.md#safety-and-privacy) list them. The important ones for you: disconnect battery and USB while an SPI programmer is attached; the camera's logic is **1.8 V**, so use a 1.8 V-capable programmer or adapter and a 1.8 V UART; never connect two power sources to one rail.
- **Privacy.** Flash dumps and overlay backups contain your Wi-Fi password (`station.hex`), device identity and cloud keys. Keep them outside any Git repository and do not share them. `build/`, `vendor/`, `wifi-config/` and `station.hex` are ignored by this repository's `.gitignore`, but that is a precaution only.
- **Every installer writes to flash** (the 704 KB `rootfs_data` overlay at `/dev/mtdblock5`). They are written to be safe (hash checks, refusals, automatic rollback on failure, an exact `rollback.sh`), but a power loss during the write can still damage the overlay. Keep the camera on USB power, take the overlay backup first, and only continue if you are prepared to recover over UART or by re-flashing.
- You are responsible for what you do to your own hardware. Nothing here is endorsed by the manufacturer.

## What you need

Hardware:

- RH-PD10 camera, and a way to power it from USB.
- SPI programmer for the first flash and backup: a CH341A with a **1.8 V adapter** and a SOIC-8 clip (the chip on the verified unit is a Winbond W25Q64JW, 8 MiB, in a 208 mil package). See [flash backup](flash-layout.md#backup-procedure).
- A **1.8 V** USB-UART adapter (a PL2303G-based one was used; check its VCCIO setting, do not assume). Wiring and cautions: [UART diagnostics](uart-pinout.md). Interactive work needs the adapter's TX connected to the camera's RX as well; validate the level before you connect it.

Host:

- `flashrom`, `python3` (3.9 or newer, standard library only), `picocom` or `screen`, `git`.
- Docker, only if you want to rebuild the binaries ([building](building.md)). The repository ships the exact binaries that were tested, so you can skip it.
- Linux or macOS. The UART helpers use `termios` and are not Windows-compatible.

All helper scripts read the serial device from the environment:

```sh
export DOORVIEW_UART=/dev/ttyUSB0            # Linux, example
export DOORVIEW_UART=/dev/cu.usbserial-XXXX  # macOS, example
```

The root password is read from a file or from stdin, never from the command line. Keep it in a private file outside the repository and point the commands at it:

```sh
install -m 600 /dev/null ~/.doorview-root && cat > ~/.doorview-root     # type the password, then Ctrl-D
export DOORVIEW_PW=$HOME/.doorview-root
```

After a fresh OpenIPC flash the password is the OpenIPC default (check the OpenIPC wiki for the current value); set your own at once with `passwd`, long and unique. **This password is the administrator password of the whole camera:** the web interface on port 80 (with a terminal, a configuration API, firmware update and factory reset), RTSP and SSH all use it, in clear text, and there are no other accounts or roles. Do not give it to other systems and keep the camera's network closed to everything that does not need it ([known limits](known-limits.md)).

## Step 1. Back up the factory flash

Follow [Flash backup and layout](flash-layout.md#backup-procedure): two complete reads, identical SHA-256, stored privately in at least two places. Do not continue without it.

## Step 2. Read your camera's MAC address from the backup

The setup uses the camera's own factory MAC address for the Wi-Fi interface. It is stored in the factory firmware's JFFS2 data as a file named `mac` (12 hex characters, no separators):

```sh
python3 tools/jffs2-files.py cat original-a.bin mac
```

If that reports several different contents, run `list original-a.bin mac` and look at each copy; the factory firmware keeps a backup of its data partition. Write the value down. Using any other address was not tested. Also keep your backup: this is the only place the value lives once you flash.

## Step 3. Flash OpenIPC

See [Installing OpenIPC](openipc-flash.md). Afterwards the camera must boot to a Linux login on the UART with `U-Boot 2022.10` and `Linux version 4.9.37`.

## Step 4. First boot and checks

Open the console (`picocom -b 115200 "$DOORVIEW_UART"`), log in as `root`, and confirm the layout the installers expect:

```sh
grep -E ' / | /overlay ' /proc/mounts      # overlay on /, /dev/mtdblock5 on /overlay (jffs2)
cat /proc/mtd                               # mtd5 is rootfs_data, 0xb0000 (720896) bytes
uname -r                                    # 4.9.37
df -k /overlay                              # about 700 KB total
```

The installers refuse to run if the overlay is not `/dev/mtdblock5` as jffs2, or if `/etc`, `/etc/doorview` or `/etc/init.d` is masked by another mount. If your layout differs, stop: it is a different build and the module binaries may not match.

## Step 5. Back up the overlay (before every stage)

```sh
python3 tools/backup-overlay.py overlay-a.bin < "$DOORVIEW_PW"
python3 tools/backup-overlay.py overlay-b.bin < "$DOORVIEW_PW"
shasum -a 256 overlay-a.bin overlay-b.bin     # must match
```

This reads `/dev/mtdblock5` read-only over the UART and takes a few minutes. Keep the files private (they will contain your Wi-Fi password after stage 1). Repeat before each later stage; the overlay changes with every install. The two files must be identical: if they differ, something wrote to the overlay between the reads (the cron job that saves the clock, or the shell history of your own sessions), so take the pair again without running other commands in between.

## Step 6. Stage 1: Wi-Fi base

Create the Wi-Fi configuration on your computer. The passphrase is asked for without echo:

```sh
python3 tools/make-wifi-config.py --ssid "YourNetwork" --address 192.0.2.10/24 --mac aa:bb:cc:dd:ee:ff --out wifi-config
```

- `--address` is a **static** IPv4 address and prefix on your camera's network. Reserve it in your router. DHCP from the camera was never verified.
- `--mac` is the value from step 2.
- SSID and passphrase are each limited to 31 bytes by the drivers; the radio is 2.4 GHz only.

Build the package, pack the configuration and send both. The archives travel as base64 over the UART at roughly 800 bytes per second, so this takes about a minute. They unpack into `/tmp/doorview-upload` on the camera; the file names of the two archives do not collide. **Never remove or reuse `/tmp/lcd-vo-test`**: it is the runtime directory of the LCD service (it copies its program and scripts there at boot and runs them from there), and deleting it makes the screen stop lighting until the service is restarted or the camera reboots.

```sh
tools/package.sh stage1-wifi
tar -czf wifi-config.tar.gz -C wifi-config .
python3 tools/upload-archive.py build/packages/stage1-wifi.tar.gz "$DOORVIEW_PW"
python3 tools/upload-archive.py wifi-config.tar.gz "$DOORVIEW_PW"
```

Install and configure on the camera (UART shell). Every stage starts from an empty `/tmp/doorview-upload`; it lives in RAM, so a reboot between stages clears it, and `rm -rf /tmp/doorview-upload` does it by hand:

```sh
cd /tmp/doorview-upload
sh install.sh .        # prints WIFI_BASE_INSTALLED
sh configure.sh .      # prints WIFI_CONFIGURED
rm -f station.hex address mac
```

Delete the local `wifi-config` and `wifi-config.tar.gz` too: `station.hex` is your Wi-Fi password in hex. Then reboot the camera (`reboot`). **If Wi-Fi does not come up, disconnect all power for a few seconds and reconnect USB**: a software reboot does not reset the Wi-Fi coprocessor, and a dead data path was only ever fixed by a power cycle.

Verify (UART):

```sh
dmesg | grep -E 'syslink_sdio|doorview:' | tail
ifconfig dv0              # your static address
```

From your computer: `ping <address>`, then `curl -sS http://<address>/` (Majestic web UI) and the stream `rtsp://root:<password>@<address>:554/stream=0` (H.265; `ffplay -rtsp_transport tcp <url>` works).

Rollback for this stage: upload the same package again (`/tmp` does not survive a reboot; the rollback compares the installed files with the package's `SHA256SUMS`), then `cd /tmp/doorview-upload && sh rollback.sh .`. It removes the hooks and modules and keeps your Wi-Fi configuration unless you add `--purge-config`.

### Optional: lighter video profile

The Majestic defaults are 1080p, which did not decode in real time over the SDIO link in these tests (for example 71 of 100 frames before a 48 s timeout). The profile used here is 640×360 at 5 fps and 128 kb/s with the slow shutter disabled (otherwise the sensor drops to 2 fps in a dark room):

```yaml
isp:
  slowShutter: disabled
video0:
  fps: 5
  bitrate: 128
  size: 640x360
```

Write it to `/etc/majestic.yaml` on the camera (another flash write) and restart Majestic with `/etc/init.d/S95majestic restart`. A 300 s test decoded 1,504 frames at 5.03 fps.

For night vision add `nightMode: {irCutPin1: 8, lightMonitor: true}` to the same file, and install the GC2053 noise profile `/etc/sensors/iq/gc2053.ini` made by `tools/gc2053-iq.sed` (see [night vision](night-vision.md)); there `slowShutter` is `medium`, which lets the exposure last longer in the dark at the cost of video frame rate.

This profile limits snapshots too: Majestic cuts a still from `video0` and never makes it larger, so the MQTT snapshot is at most 640 × 360. For full 1920 × 1080 pictures set `size: 1920x1080` (the unit has run it since 2026-11-21): the stream then does not play in real time, but the snapshots need no video session, and each is about 120 to 170 KB (see [Snapshot](mqtt-home-assistant.md#snapshot); the broker's packet limit must allow it).

## Step 7. Stage 2: LCD and button

Take a fresh overlay backup (step 5). Then:

```sh
tools/fetch-vendor.sh                  # downloads the vendor VO module and checks its hash
tools/package.sh stage2-lcd
python3 tools/upload-archive.py build/packages/stage2-lcd.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .      # prints LCD_IRQ_INSTALLED
reboot
```

This stage replaces `S41doorview-network` with a version that prefers the interrupt-driven SDIO driver (and keeps the polling driver as a fallback), and adds the LCD service. The installer insists on **exactly** the stage 1 files (it checks the hashes of `S41doorview-network` and `syslink_net.ko`), so do not edit them. Details: [LCD and button](lcd-and-button.md).

After a reboot, press the button: the panel lights for 30 seconds with the live view. `cat /tmp/doorview-lcd-boot.log` and `cat /tmp/lcd-vo-test/button-listener.log` help if it does not.

Rollback: upload the same package again and run `sh rollback.sh` from it. It restores the stage 1 `S41doorview-network` from the copy the installer kept, and removes the LCD service and the interrupt driver.

## Step 8. Stage 3: MQTT for Home Assistant

Needs an MQTT 3.1.1 broker the camera can reach on plain TCP with a user and password (the camera's user needs write access to `doorview/<node>/#` and to the `sensor`, `binary_sensor` and `event` discovery topics under `homeassistant/`; Home Assistant's user needs to read them). See [MQTT and Home Assistant](mqtt-home-assistant.md) for topics, entities and an example Mosquitto ACL. The broker address must be an IPv4 address. If the broker is in another subnet than the camera, the camera also needs a default route (stages 1 and 2 set none): add `gateway=` to the settings file below.

```sh
tools/package.sh stage3-mqtt
python3 tools/upload-archive.py build/packages/stage3-mqtt.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints MQTT_INSTALLED
```

Create the broker settings locally in a file of mode 600 (`host=`, `port=`, `user=`, `password=`, `gateway=` when the broker is in another subnet, and `motion=1` for the optional motion sensor, which also needs `motionDetect` enabled in `/etc/majestic.yaml`; see [Motion](mqtt-home-assistant.md#motion); and `snapshot=1` to publish a picture when motion starts, see [Snapshot](mqtt-home-assistant.md#snapshot)), upload it with the same silent upload, run `sh configure.sh <file>` (prints `MQTT_CONFIGURED`), delete the local copy, and reboot. Check `cat /tmp/doorview-mqtt.log` and the new device in Home Assistant.

Rollback: upload the same package again and run `sh rollback.sh` from it. It restores the stage 2 driver from the copy the installer kept and removes the daemon and its hook; `mqtt.conf` (credentials) stays until you delete it.

## Step 9 (optional). Stage 4: drivers for the factory power cycle

Replaces two drivers so that the camera can be put to sleep and woken by the PIR: `syslink_poll.ko` accepts every wake-up reason the coprocessor reports (the stage 1 driver accepted only `poweron`) and `syslink_net_irq.ko` adds two write-only parameters, `mcu` (PIR on/off and sensitivity, nothing else is accepted) and `standby` (the factory sequence `8a:77 07`, `9a:03`, answer `8a:61 01`). It adds no boot hook: **nothing sleeps by itself**. It needs stage 3 and expects exactly the shipped stage 1 and stage 3 drivers.

```sh
tools/package.sh stage4-sleep
python3 tools/upload-archive.py build/packages/stage4-sleep.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints SLEEP_INSTALLED
```

The new drivers load at the next cold start; a software reboot would load them too but triggers the early-boot resets (see [known limits](known-limits.md)). To try them without a restart, see [factory firmware](factory-firmware.md); the owner of the unit used `echo 780100 > /sys/module/syslink_net/parameters/mcu` (PIR on) and `echo 1 > /sys/module/syslink_net/parameters/standby` after `sync`. **The sleeping SoC wakes by the PIR, the key or the power button; if it does not, press the power button.** Never send any other command to the coprocessor.

Rollback: upload the package again and run `sh rollback.sh`. It puts back the two drivers from `syslink_poll.ko.before-sleep` and `syslink_net_irq.ko.before-sleep`. If the camera does not come up after a cold start, log in on the UART during one of its boot windows and copy those two files over the drivers.

## Step 10 (optional). Stage 5: the daemon that puts the camera to sleep

Replaces the MQTT daemon with the build that supports `sleep_after` (see [MQTT and Home Assistant](mqtt-home-assistant.md#sleep)). Needs stages 3 and 4. The sleep is off until `sleep_after=` is added to `mqtt.conf`, so the new daemon behaves like the old one at first. It touches no other file.

```sh
tools/package.sh stage5-sleep-daemon
python3 tools/upload-archive.py build/packages/stage5-sleep-daemon.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints SLEEP_DAEMON_INSTALLED
```

Rollback: upload the package again and run `sh rollback.sh`; it puts back `doorview-mqtt.before-sleep`. The keys can stay in `mqtt.conf`: the old daemon ignores them. Before a session on the UART, create `/tmp/doorview-stay-awake` so that the camera does not sleep in the middle of it.

## Step 11 (optional). Stage 6: switch off the coprocessor's own wake-up timer

Replaces the MQTT daemon and `syslink_net_irq.ko` with builds that send the wake-up timer command (`8a:7b`) before every sleep. Without it the coprocessor wakes the sleeping SoC by its own timer about every 5 minutes (reason `timer`). Needs stages 4 and 5 and expects exactly their files. The daemon sends `wake_timer=<seconds>` (default 0 = off); nothing else changes.

```sh
tools/package.sh stage6-wake-timer
python3 tools/upload-archive.py build/packages/stage6-wake-timer.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints TIMER_INSTALLED
```

The new driver loads at the next cold start (after the next sleep); to try it without one, load it into the running camera as described in [factory firmware](factory-firmware.md). Rollback: upload the package again and run `sh rollback.sh`.

## Verification checklist

- [ ] Console shows `U-Boot 2022.10` and `Linux version 4.9.37`.
- [ ] `dv0` has your address and the camera answers `ping` after a cold start.
- [ ] `curl http://<address>/` returns the Majestic page; RTSP decodes.
- [ ] `dmesg | grep 'FIFO empty'` shows `empty=0` and `errors=0` (IRQ driver).
- [ ] The button lights the LCD.
- [ ] Battery and external power appear in Home Assistant; unplug USB and see it change to `OFF`.
- [ ] A **cold** start (all power removed, then USB reconnected) brings Wi-Fi back by itself.

## Recovery

- No shell, but the UART prints boot output: the boot hooks are `S39`, `S41`, `S96` and `S97`. `S39` and `S41` each wait at most about 10 s, and `S96` starts its work in the background. Remove a hook from the UART with `rm /etc/init.d/S9x...` and reboot.
- Overlay damaged or filesystem errors: restore the overlay backup only with the camera off the network and with a verified programmer; this is a flash write. The factory-flash restore path was **never tested**: a matching pair of reads does not prove a restore works.
- Wi-Fi dead while the UART works: power-cycle first (see [troubleshooting](troubleshooting.md)).
