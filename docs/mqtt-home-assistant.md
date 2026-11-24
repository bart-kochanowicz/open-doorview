# MQTT and Home Assistant

`doorview-mqtt` is a small daemon (13 KB, static ARM, no libc) that publishes the camera's battery, external power, button, uptime and, optionally, motion to an MQTT broker, with Home Assistant MQTT discovery so the entities appear on their own. It is stage 3 of the [install guide](install-guide.md#step-8-stage-3-mqtt-for-home-assistant).

**Status:** stage 3 is installed on one camera and was observed for minutes to hours and three reboots (see [known limits](known-limits.md)). The build in this repository adds the optional motion sensor and a keepalive fix. It ran from RAM first and was then installed with `motion=1` on 2026-11-20 (the newest build, with the snapshot, was installed the same day, see [known limits](known-limits.md)): against the real Mosquitto broker and a real Home Assistant the Motion entity went ON when a hand was waved in front of the lens and OFF about 10 s later, before and after a reboot. The logic is covered by 77 tests against a real Mosquitto in Docker (`firmware/userland/mqtt/tests/run-tests.sh`), including a fake Majestic and an ASan/UBSan build.

## What it needs

- An MQTT **3.1.1** broker reachable from the camera on plain TCP, with a user and password. There is no TLS: the password crosses your network in clear text, so keep the camera and broker on a network you trust (the camera does have an mbedTLS library, but this client does not use it).
- The broker address must be an **IPv4 address**. The daemon has no DNS.
- A route from the camera to the broker. Stages 1 and 2 configure only the on-link route of the camera's own subnet, so a broker in another subnet is "Network unreachable" until a default route exists (observed on the unit, 2026-11-20). Put `gateway=<IPv4 of the router>` in `mqtt.conf` (below); `S97doorview-mqtt` then adds the default route at boot if none exists.
- The camera's user needs *write* access to `doorview/<node>/#` and to the discovery topics of the components the daemon uses (`sensor`, `binary_sensor`, `event`, and `image` when `snapshot=1`), and nothing else. A broker that does not allow `image` silently drops that one discovery message; you can then declare the image entity by hand in Home Assistant instead. An example Mosquitto ACL (as used in the tests; `front-door-camera` is the default node name):

  ```
  user home-assistant
  topic readwrite #

  user front-door-camera
  topic write doorview/front-door-camera/#
  topic write homeassistant/sensor/front-door-camera/+/config
  topic write homeassistant/binary_sensor/front-door-camera/+/config
  topic write homeassistant/event/front-door-camera/+/config
  topic write homeassistant/image/front-door-camera/+/config
  ```

  with `allow_anonymous false` and a password file. The tests check that the camera user cannot publish anywhere else.

## Entities

| Entity | Source | Notes |
|---|---|---|
| Battery (%) | PowerInfo `A2`, int16 capacity | Only values 0 to 100 are published; a negative capacity means "no fresh reading" and the cached value stays. The scale is **assumed** to be percent: only 99 was ever observed. |
| External power | `A2` usb byte | `ON` / `OFF`. Verified by unplugging USB: OFF within one burst, ON again after replugging. |
| Power status (diagnostic) | `A2` status byte | The raw value: 1 on battery, 2 with USB. Whether 2 is "charging" or "full" is unknown. |
| Button (event entity) | `A5` records | A press is a burst of records, counted once (250 ms window). History from before the daemon started is not replayed. |
| Uptime (diagnostic) | `/proc/uptime` | Every 60 s, not retained. |
| Motion (optional, `motion=1`) | Majestic's `md_rects_acc_total` | A binary sensor (`device_class: motion`). ON when the counter rises, OFF `motion_hold` seconds (default 10) after the last rise. See [Motion](#motion). Retained. |
| Snapshot (optional, `snapshot=1`) | Majestic `/image.jpg` | An `image` entity. The JPEG taken when motion starts, published retained to `doorview/<node>/snapshot` (about 120 to 170 KB at the default 1920 × 1080; about 12 KB at 480 × 270). See [Snapshot](#snapshot). |
| Availability | MQTT last will | `online` retained; the broker publishes `offline` (retained) if the camera disappears. |

States are retained; button events and uptime are not. Topics are `doorview/<node>/...`; discovery is `<discovery>/<component>/<node>/<object>/config`, with unique ids prefixed by the node name.

The camera does not send a clean `offline` when the daemon is stopped; Home Assistant sees it after about 1.5 × the keepalive (90 s by default). If the broker or Wi-Fi is down the daemon only retries, with a backoff from 2 s doubling up to 60 s, and it republishes everything after reconnecting.

## Configuration

`/etc/doorview/mqtt.conf`, mode 600, created by `configure.sh` from a file you upload silently:

```
host=192.0.2.20
port=1883
user=front-door-camera
password=...
# optional
gateway=192.0.2.1
node=front-door-camera
name=Front door camera
discovery=homeassistant
keepalive=60
wifi_watchdog=0
motion=1
motion_port=80
motion_hold=10
snapshot=1
snapshot_path=/image.jpg?qfactor=60
snapshot_cooldown=30
motion_settle=60
wifi_reboot=120
```

`gateway` is the router of the camera's subnet. It is only used by `S97doorview-mqtt` (the daemon ignores the key), and only when the camera has no default route yet. Leave it out when the broker is in the camera's own subnet.

`configure.sh` rejects hostnames, a gateway that is not an IPv4 address, a missing user or password, unknown keys, bad ports, over-long values and symlinks, and it prints nothing from the file. Without this file `S97doorview-mqtt` starts nothing, so installing the package is harmless until you configure it.

`motion=1` turns the motion sensor on (default 0, no entity is created); `motion_port` is the port of Majestic's web server on the camera itself (default 80) `motion_hold` the seconds the sensor stays ON after the last rise of the counter (1 to 600, default 10), and `motion_min_rate` with `motion_window` a threshold on how fast it rises (see [Motion](#motion)): `motion_min_rate` is the rectangles per second the counter must gain, measured over the newest stretch of at least `motion_window` seconds (1 to 10, default 3); 0, the default, means any rise.

`snapshot=1` (default 0; needs `motion=1`) publishes a picture when motion starts. `snapshot_path` is the request path on the camera's own web server (default `/image.jpg?qfactor=60`; `width` and `height` can make the picture smaller but never larger than the main stream, see [Snapshot](#snapshot); letters, digits and `/ . _ - ? & = %` only, so it cannot add a header line) `live=1` (default 0) enables the [live view](#live-view) with `live_seconds` (1 to 300, default 30), `live_interval_ms` (100 to 5000, default 500) and `live_path` (the request for each picture, default `/image.jpg?width=640&height=360&qfactor=40`); `snapshot_cooldown` the minimum seconds between pictures (1 to 3600, default 30), `night_wait_ms` how long the picture may wait for Majestic's night mode in the dark (0 to 8000 ms, default 0 = no wait; see [install guide, step 18](install-guide.md#step-18-optional-stage-13-the-night-picture-after-a-wake-up)) and `snapshot_delay_ms` how long after the motion edge the picture is taken (0 to 5000 ms, default 0): the first frame after a change of light can be nearly black, and a person at a door may not be in view yet. `wake_server=<IPv4>:<port>` with `wake_pattern=<12 hex digits>` (both or neither; they need `sleep_after`; `wake_interval` 10 to 3600 s, default 60; `wifi_parameter` the driver's path) arms the coprocessor's keep-alive before every standby so that the server can wake the camera, and a wake-up with the reason `wifi` starts the live view by itself when `live=1` ([waking from the network](remote-wake.md), stage 14).

`motion_settle=<seconds>` (0 to 600, default 0) ignores every rise of the motion counter for that long after the daemon starts and after Majestic restarts (a counter that goes down). **Observed in the Home Assistant recorder on 2026-11-22:** after each of three restarts in the dark the sensor went ON for about 20 seconds, 29 to 50 seconds after the boot, and the automation sent a "no snapshot arrived" notification; the likely cause is the night switch and the detector settling (assumed, not measured: a daylight reboot gave a counter at 0 for 71 s). 60 covers the observed window.

`wifi_reboot=<seconds>` (0 = off, the default; 30 to 3600 in `configure.sh`) restarts the camera (`sync`, then the `reboot` system call) when the broker has been unreachable for that long **and** the kernel's received-packet counter of `dv0` has not changed for that long, but never before four times that long have passed since the daemon started, so a path that is dead from boot on cannot make a tight restart loop. Why: see [the overnight stalls](wifi-companion.md#the-data-path-stalls-of-2026-11-22). The camera recovered from all three stalls by restarting; the daemon's restart is the same restart done sooner (assumed equivalent to the watchdog's, not proven on the unit).

`wifi_watchdog=1` makes the daemon request a station reconnect when the broker has been unreachable for 3 minutes and no frame was received for 90 s, at most once per 5 minutes. It is **off by default**: in the one case where a software reconnect was tried on a dead Wi-Fi data path it did not help.

## Motion

Majestic (the camera's video service) has a hardware motion detector, off by default. Enable it with this in `/etc/majestic.yaml` (a flash write; restart Majestic with `/etc/init.d/S95majestic restart`):

```
motionDetect:
  enabled: true
```

Majestic then serves Prometheus counters at `/metrics/motion`; with detection off it reports zeros and never rises. The daemon reads `md_rects_acc_total` (rectangles the detector reported inside the region of interest) from `127.0.0.1` once per second. Requests from the camera itself need no password (observed: the camera's own requests skip Majestic's authentication, while requests from the network get `401`). A counter that goes down means Majestic restarted and is treated as a new baseline, not as motion; a `401` page, an answer without the counter or a half-written line is ignored; if Majestic disappears while the sensor is ON, it still goes OFF after the hold time.

**Noise and the rate threshold.** In a nearly dark room the detector's counter rises by itself (sensor noise), which would hold the sensor ON for good (observed: almost eight minutes). With `motion_min_rate` the daemon turns Motion ON only when the counter gained at least that many rectangles per second over the last `motion_window` seconds, so slow noise stays below it while a real movement, which gives several times the noise rate, rises above it. The comparison is `rectangles gained * 1000 >= motion_min_rate * elapsed milliseconds` (no division: the freestanding ARM build has none); the first `motion_window` seconds after the daemon starts, or after the counter went down (Majestic restarted), decide nothing. The hold time still applies after the last qualifying poll. How the noise and the movement compare in practice is in [night vision](night-vision.md).

Observed on the unit (one camera, 2026-11-20): the counter rose from 0 to 148 and to 201 in two hand-waving tests, the load average did not change, and the Home Assistant entity followed. **Not known:** the false-alarm rate (shadows, light changes, the corridor outside), the effect of the default sensitivity and region of interest, behaviour over days and at night.

## Snapshot

**Why the camera pushes the picture instead of Home Assistant pulling it.** The camera's web interface (Majestic, port 80) has one administrator account, the root password: its `access.cgi` page changes the root password, and it offers a terminal (`console.cgi`), a file manager, the configuration API (`/api/v1/set`), firmware update and factory reset. There are no roles. A second account (the root password is also what RTSP and SSH use) would be the same administrator under another name, sent in clear text over HTTP. So nothing outside the camera should be given a credential for port 80. (Read from the CGI scripts and the web server's route list on the unit; the pages were fetched from the camera itself, no remote administrator action was tried.) Requests from the camera itself skip authentication (observed), so the daemon can fetch the picture locally and send it over the connection it already has to the broker. Home Assistant needs no route and no password for the camera.

On the Motion edge OFF to ON (not on every poll) the daemon requests `snapshot_path` from `127.0.0.1`, checks that the answer is `200` and that the body starts with the JPEG start marker and ends with the end marker (a half-read or an error page is never published), and publishes it retained to `doorview/<node>/snapshot`. At most one picture per `snapshot_cooldown` seconds; a picture whose edge is more than 10 s old (the broker was unreachable) is dropped. The picture is read into a static buffer and the MQTT header is written in front of it, so it is not copied; pictures above 320 KB are not published. The send gives up after 5 s without progress, not 5 s in all.

**Resolution.** Majestic cuts a still from the main stream (`video0`) and never makes it larger: with `size: 640x360` every request, whatever `width` and `height` say, is at most 640 by 360 (observed on the unit; smaller values such as 480 by 270 were honoured). Since 2026-11-21 the unit runs `video0.size: 1920x1080`, so the default request gives a full 1920 by 1080 picture. Measured on the unit (observed): 123 KB at `qfactor=40`, 142 KB at 50, 165 KB at 60 (1920 by 1080, a dim indoor scene); 67 KB at 1280 by 720 with the default quality. Sending a picture of 135 to 168 KB over the Wi-Fi took 3.9 to 4.9 s (the log line `snapshot published, N bytes in M ms`), about 34 KB/s. The broker must accept the packet: the production broker's `max_packet_size` was raised to 512 KiB for this, and a larger packet makes it drop the camera.

**Cost of a 1080p main stream.** The RTSP and HTTP video (`stream=0`) is then 1080p at 5 fps and 128 kb/s, which the earlier tests showed does not play in real time over the SDIO link; live video was not retested at this size. The LCD preview uses a separate scaler output and was reported working by the owner after the change. To get live video back, set `video0.size` to `640x360` (and accept 640 by 360 stills).

## Live view

Home Assistant has no route to the camera (its web interface gives root to any login), so a live picture also goes through the broker, as a slide show on demand. With `live=1` the daemon subscribes, after every connection, to `doorview/<node>/live/set`.

| Topic | Who | Payload |
|---|---|---|
| `doorview/<node>/live/set` | Home Assistant publishes | `ON` or `OFF`, QoS 0, **not retained** |
| `doorview/<node>/live` | the camera publishes | one JPEG (about 10 to 25 KB at 640 by 360), QoS 0, **not retained**, at most one per `live_interval_ms`, only while a view runs |
| `doorview/<node>/live/state` | the camera publishes | `ON` or `OFF`, **retained**; `OFF` after every (re)connection |

`ON` starts a view and sets its end to `live_seconds` from that moment (another `ON` during a view restarts the time); `OFF` or the end stops it, and the state follows. Each picture is requested from Majestic on the loopback interface (`live_path`), checked to be a complete JPEG, and published. A picture that Majestic cannot give is skipped and logged once per view. The end of a view is logged with what it cost, for example `live view ended, 21 pictures, 312000 bytes in 30010 ms`, which gives the real picture size and rate over the link. **Observed on the unit (2026-11-22, three views from the Home Assistant app):** `13 pictures, 147156 bytes in 6723 ms`, `11 pictures, 127154 bytes in 5635 ms` and `34 pictures, 355851 bytes in 18376 ms`, that is about 11 KB per picture, 1.9 pictures per second and 19 to 23 KB/s. A motion snapshot is still taken while a view runs; the view pauses while it is sent (a large night picture can take several seconds at about 35 KB/s).

What the daemon ignores on the command topic, on purpose: any payload other than exactly `ON` or `OFF`; any message with the retain flag (a retained `ON` would start a view at every reconnect); any message above QoS 0. A message too large for the daemon's 512-byte receive buffer is dropped as it arrives (earlier, a too-large packet closed the connection, which would have let anyone who can publish there disconnect the camera). Home Assistant's user and the camera are the only ones with access to these topics; anyone with write access to `.../live/set` can start a view.

**The broker's ACL needs one line for the camera:** `topic read doorview/front-door-camera/live/set` (its write line `doorview/front-door-camera/#` already covers the pictures and the state). Without it Mosquitto 2.1 still answers the subscription with a granted SUBACK and delivers nothing (observed: SUBACK `9003000100`), so the camera cannot tell and the view just never starts. Home Assistant declares the entities by hand (the ACL permits no discovery for them).

Tested with a real Mosquitto and a fake Majestic (see the test suite): pictures that match what Majestic served, not retained, at most one per interval, the end by time and by `OFF`, the restart by a second `ON`, ignored payloads and retained `ON`, a 70,000-byte payload on the command topic without a disconnect, a motion snapshot during a view, a Majestic that answers with a page that is not a JPEG, and the configuration refusals. **Not yet run on a camera**: the real picture size, the time per picture over the SDIO link, and how it affects the Wi-Fi.

## Sleep

`sleep_after=<seconds>` (0 = off, the default; otherwise 10 to 3600) puts the camera to sleep like the factory firmware when nothing has happened for that long. It needs `snapshot=1` (so also `motion=1`), the stage 4 drivers (`firmware/stage4-sleep`) and, to wake by itself, a PIR that is switched on, which the daemon does before every sleep. **Status:** the logic is covered by tests against a real broker (host build); it has not run on a camera yet, see [known limits](known-limits.md).

What the daemon does, in this order, when the camera has been idle for `sleep_after` seconds and nothing blocks it:

1. publishes `availability` = `offline` (retained) and closes the connection cleanly, so Home Assistant shows the camera as offline at once, not after the keep-alive;
2. writes the wake-up timer to the `mcu` parameter of the syslink driver (`mcu_parameter=` changes the path): `7b` and `wake_timer=<seconds>` as four little-endian bytes. **0, the default, switches the coprocessor's own timer off:** without this command the coprocessor wakes the SoC by itself about 5 minutes after every sleep (observed on 2026-11-23: wake-ups with the reason `timer`), which costs more than a fifth of the battery life; a value such as 21600 wakes it every 6 hours so that the battery value is refreshed;
3. writes `780100` to the same parameter (PIR on);
4. syncs the file systems;
5. writes `1` to the `standby` parameter (`standby_parameter=`): the driver sends `8a:77 07` and `9a:03` and answers the coprocessor's `0xa0`, which then switches the SoC off.

If the camera is still running 30 s later it logs that, reconnects, and does not try again for five minutes.

**Idle** means no motion, no button press, no PIR alarm while awake, no live view and no picture published for `sleep_after` seconds. **Blocked** means: a live view is running, a picture is still to be sent, the motion sensor is on, a button press is still to be published, the first power frame has not arrived, or the camera is on USB power (set `sleep_usb=1` to sleep there too), or the file `/tmp/doorview-stay-awake` exists (`stay_awake_file=`): create it before a session on the UART, because a camera that goes to sleep in the middle of one needs the power button. The log says `sleep postponed` once.

**Wake-up.** The reason the coprocessor gave is in `/sys/module/syslink_poll/parameters/reason` (`reason_file=`). For `pir` the daemon publishes motion `ON` and one snapshot as soon as it is connected, so the existing Home Assistant automations (notification, archive, person detection) run unchanged; wait for the picture with `snapshot_delay_ms=1500`, because the first frame after a start can be dark. Other reasons (`poweron`, `key`, `timer`...) only start the idle count. **A press of the front button that wakes the camera is consumed by the coprocessor: the LCD preview does not start for that press.**

While the camera sleeps, every entity of the device is unavailable in Home Assistant (the camera is offline; the retained battery value is kept by the broker but not by the entities). Only stage 14 lets Home Assistant wake it: with `wake_server`/`wake_pattern` the homelab relay wakes the camera when the live view is switched on (`live/set` `ON`) while it sleeps, and the live view then starts by itself ([waking from the network](remote-wake.md#the-relay)).

## How it works

It opens `/dev/kmsg` and parses the `doorview_control` and `doorview_power` lines the stage 3 network driver writes ([coprocessor](wifi-companion.md#control-frames-from-the-mcu)). Because it needs the `doorview_power` line, stage 3 replaces the stage 2 driver with a build that adds it; the button line the LCD service matches is unchanged. A single poll loop handles the kernel log, the socket and the timers; connecting is non-blocking. The motion poll is a short exchange on its own socket (bounded to 300 ms, stopped as soon as the line is complete), so a slow Majestic cannot stall the MQTT connection for long. The daemon pings the broker when it has heard nothing for half the keepalive, even while it is publishing: the broker acknowledges nothing the daemon publishes, so a daemon that publishes often would otherwise declare the broker dead (found by the motion tests).

Source: `firmware/userland/mqtt/`. `doorview-mqtt.c` is the main loop and the configuration structure; it includes the logic from `parts/` by topic (`config`, `mqtt`, `state`, `motion`, `snapshot`, `live`, `kmsg`, `watchdog`, `connection`, `sleep`), so the daemon is one translation unit. `sys-arm.c` is a raw-syscall layer for the camera; `sys-host.c` is a POSIX layer used only by the tests.

## Known limits

- Plain TCP, no TLS.
- No clean `offline` on stop.
- IPv4 literal only.
- Roughly 100 minutes of total stability observation exist for the interrupt-driven driver the daemon runs on top of; the daemon adds a TCP connection on top of that.
