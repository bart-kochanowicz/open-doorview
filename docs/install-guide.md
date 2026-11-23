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

For night vision add `nightMode: {irCutPin1: 8, lightMonitor: true, autoNightGain: 16, autoDayGain: 4, autoNightDelay: 1, monitorDelay: 1}` to the same file (the four timing values make night mode start within the first seconds after a wake-up, see [night vision](night-vision.md#night-mode-right-after-a-wake-up-2026-11-23)), and install the GC2053 noise profile `/etc/sensors/iq/gc2053.ini` made by `tools/gc2053-iq.sed` (see [night vision](night-vision.md)); there `slowShutter` is `medium`, which lets the exposure last longer in the dark at the cost of video frame rate.

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

## Step 12 (optional). Stage 7: the PIR as the motion source

Replaces the MQTT daemon with the build that supports `pir_motion=1` (an alarm start from the PIR while the camera is awake is a motion edge with a snapshot, like a PIR wake-up; the daemon switches the PIR on at start), `pir_sensitivity=1..3` (written before the PIR is switched on; leave it out to keep what the coprocessor has) and `motion_video=0` (Majestic's video motion detector is not polled). All three are off by default. Needs stage 6; touches no other file. Together with `motionDetect: enabled: false` in `/etc/majestic.yaml` this ends the "motion" events that the video detector invented (lights, shadows) and that kept the camera awake.

```sh
tools/package.sh stage7-pir-motion
python3 tools/upload-archive.py build/packages/stage7-pir-motion.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints PIR_DAEMON_INSTALLED
```

Rollback: upload the package again and run `sh rollback.sh`.

## Step 13 (optional). Stage 8: a faster start

Replaces three start-up scripts: `/etc/init.d/rcS` (skips the system and kernel log, the random seed, the fake hardware clock, mdev, NTP, cron and the tunnels, and starts the Wi-Fi link and the camera stack side by side; a failsafe boot is the stock one), `S39doorview` and `S41doorview-network` (they poll every 0.1 s instead of sleeping a fixed second). Measured on the unit on 2026-11-23: Majestic started 8.9 s after the U-Boot banner instead of 11.4 s. Needs stages 1 to 3; expects exactly the shipped scripts and the stock `rcS`. Nothing else changes, but **the camera no longer keeps a system log (`logread` is empty) and runs no NTP**: the clock is whatever the RTC says. SSH (dropbear) still starts, in the background.

```sh
tools/package.sh stage8-fast-boot
python3 tools/upload-archive.py build/packages/stage8-fast-boot.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints FAST_BOOT_INSTALLED
```

The old scripts are kept as `/etc/doorview/<name>.before-fast` (not in `/etc/init.d`, where the stock `rcS` would run them). Rollback: upload the package again and run `sh rollback.sh`; it writes the stock `rcS` back as a file. If the camera does not come up after a cold start, log in on the UART during a boot window and run the same rollback, or `cp /etc/doorview/rcS.before-fast /etc/init.d/rcS` and the same for the other two scripts.

## Step 14 (optional). Stage 9 and the manual trimming

Stage 9 (`stage9-lean`) replaces `/etc/init.d/rcS` (the stage 8 script without zram swap and the SSH server) and `/usr/bin/load_goke` (the stock vendor loader without the six audio modules). Needs stage 8; expects exactly its `rcS` and the stock loader. The old files are kept as `/etc/doorview/<name>.before-lean`; rollback writes them back.

```sh
tools/package.sh stage9-lean
python3 tools/upload-archive.py build/packages/stage9-lean.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints LEAN_INSTALLED
```

Three changes were made by hand on the unit on 2026-11-23, each after two identical backups of the overlay (and of the U-Boot environment for the last one):

- `/etc/majestic.yaml`: `rtsp`, `onvif` and `audio` with `enabled: false` (no listener on 554 and 3702 any more; mDNS on 5353 stays, its key was not found). The video motion detector was already off (`motionDetect: enabled: false`).
- **The web panel is hidden:** `rm -rf /var/www` on the running system replaces every file of the panel (pages and CGI scripts, among them a browser console) by an overlay whiteout; three empty directories remain because this overlay cannot hide directories. Majestic's own endpoints (`/image.jpg`, `/metrics`) keep working; `/` answers 500 and the CGI scripts 404. To undo: `rm -rf /overlay/root/var/www` and restart.
- **U-Boot:** `fw_setenv extras quiet` (the kernel stops writing its messages to the UART at 115200 baud, about 0.7 s) after `fw_setenv bootdelay 0` (1 s). Only these variables changed. To undo: `fw_setenv extras` and `fw_setenv bootdelay 1`.

## Step 15 (optional). Stage 10: the daemon starts with the Wi-Fi link

Stage 10 (`stage10-early-daemon`) replaces `/etc/init.d/rcS` (the stage 9 script that starts the MQTT daemon right after the Wi-Fi link, in parallel with the camera stack, and brings up only the loopback of the stock network start) and `/etc/doorview/doorview-mqtt` (the build that retries the first picture every 200 ms while Majestic is still starting, sets the PIR up after that picture, and retries a busy coprocessor command instead of waiting a fixed time). Needs stages 7 and 9; the old files are kept as `/etc/doorview/<name>.before-early`.

```sh
tools/package.sh stage10-early-daemon
python3 tools/upload-archive.py build/packages/stage10-early-daemon.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints EARLY_DAEMON_INSTALLED
```

Also changed by hand on the unit (2026-11-23): the kernel parameters in the U-Boot variable `extras` are now `quiet printk.time=1 initcall_blacklist=femac_mdio_driver_init,femac_driver_init` (the ethernet driver, which waited 0.85 s for a PHY this camera does not have, is not started; the kernel log keeps its time stamps), and the picture is `snapshot_path=/image.jpg?width=960&height=540&qfactor=55` (about 48 KB, 1.0 s over the Wi-Fi). To undo the kernel part: `fw_setenv extras quiet`.

## Step 16 (optional). Stage 11: the preview after a front-button wake-up

**Not run on a camera yet.** The press of the front button that wakes a sleeping camera is consumed by the coprocessor and never reaches the button listener, so no preview starts. Stage 11 (`stage11-wake-preview`) replaces `/etc/init.d/S96doorview-lcd`: when the wake-up reason is `wifikey` (the front button, observed) or `key`, it waits until Majestic gives a picture (at most 20 s), starts the LCD service and runs the preview once; any other start keeps the 20 s delay and waits for a press as before. The old hook is kept as `/etc/doorview/S96doorview-lcd.before-wake`.

```sh
tools/package.sh stage11-wake-preview
python3 tools/upload-archive.py build/packages/stage11-wake-preview.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints WAKE_PREVIEW_INSTALLED
```

## Step 17 (optional). Stage 12: the highest PIR sensitivity

The factory app has three PIR sensitivity settings and sends them to the coprocessor as the values 1, 3 and 5 (read from the factory firmware, `IPC_APP_set_pir_ctl`); 3, the factory's middle setting, was the highest the drivers accepted. Stage 12 (`stage12-pir-high`) replaces `/etc/doorview/syslink_net_irq.ko` (the stage 6 driver with the range 1 to 5 for `8a:79`) and `/etc/doorview/doorview-mqtt` (the stage 10 daemon with `pir_sensitivity=0..5`). Needs stages 6 and 10; the old files are kept as `/etc/doorview/<name>.before-high`. **Observed on the unit (2026-11-23):** both builds ran from RAM first; at level 5 every walk into the picture produced PIR alarm frames while the camera was awake, where level 3 had produced none in the same kind of test.

```sh
tools/package.sh stage12-pir-high
python3 tools/upload-archive.py build/packages/stage12-pir-high.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints PIR_HIGH_INSTALLED
sed -i 's/^pir_sensitivity=.*/pir_sensitivity=5/' /etc/doorview/mqtt.conf
```

Rollback: set `pir_sensitivity=3` (or less) first, because the old daemon refuses 5 and would not start; `rollback.sh` refuses while 4 or 5 is configured.

## Step 18 (optional). Stage 13: the night picture after a wake-up

A wake-up starts Majestic in day mode; in the dark the first picture came before the IR LEDs were on, dark and in colour, even with the night settings of [night vision](night-vision.md#night-mode-right-after-a-wake-up-2026-11-23). Stage 13 (`stage13-night-wait`) replaces `/etc/doorview/doorview-mqtt` with the build that reads `night_wait_ms` (0 to 8000, default 0 = off): before the picture it asks Majestic's `/metrics/night`, and while the light is not measured yet (`night_auto_gain_milli -1`) or Majestic is counting toward night (`night_auto_pending 1`) it waits, every 200 ms and at most that long; in night mode, in daylight or without these metrics it takes the picture at once. Needs stage 12; the old daemon is kept as `/etc/doorview/doorview-mqtt.before-night` and ignores the key. **Observed on the unit (2026-11-23):** from RAM, with Majestic restarted and the IR pin set low by hand (as after a cold start), the daemon logged `waiting for night mode` and published a black-and-white infrared picture 3.7 s after Majestic's start, in which a person is clearly visible; before, the first picture of a wake-up in the dark was dark and in colour. After installing it, a real PIR wake-up in the dark gave an IR-lit picture with the person clearly visible (in colour with a violet cast: Majestic moves the filter and lights the LEDs before it switches the picture to grey).

```sh
tools/package.sh stage13-night-wait
python3 tools/upload-archive.py build/packages/stage13-night-wait.tar.gz "$DOORVIEW_PW"
# on the camera:
cd /tmp/doorview-upload && sh install.sh .       # prints NIGHT_WAIT_INSTALLED
echo night_wait_ms=4000 >> /etc/doorview/mqtt.conf
```

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
