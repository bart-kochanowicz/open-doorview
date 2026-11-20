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
| Snapshot (optional, `snapshot=1`) | Majestic `/image.jpg` | An `image` entity. The JPEG taken when motion starts, published retained to `doorview/<node>/snapshot` (about 12 KB at the default size). See [Snapshot](#snapshot). |
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
snapshot_path=/image.jpg?width=480&height=270&qfactor=40
snapshot_cooldown=30
```

`gateway` is the router of the camera's subnet. It is only used by `S97doorview-mqtt` (the daemon ignores the key), and only when the camera has no default route yet. Leave it out when the broker is in the camera's own subnet.

`configure.sh` rejects hostnames, a gateway that is not an IPv4 address, a missing user or password, unknown keys, bad ports, over-long values and symlinks, and it prints nothing from the file. Without this file `S97doorview-mqtt` starts nothing, so installing the package is harmless until you configure it.

`motion=1` turns the motion sensor on (default 0, no entity is created); `motion_port` is the port of Majestic's web server on the camera itself (default 80) and `motion_hold` the seconds the sensor stays ON after the last rise of the counter (1 to 600, default 10).

`snapshot=1` (default 0; needs `motion=1`) publishes a picture when motion starts. `snapshot_path` is the request path on the camera's own web server (default `/image.jpg?width=480&height=270&qfactor=40`; letters, digits and `/ . _ - ? & = %` only, so it cannot add a header line) and `snapshot_cooldown` the minimum seconds between pictures (1 to 3600, default 30).

`wifi_watchdog=1` makes the daemon request a station reconnect when the broker has been unreachable for 3 minutes and no frame was received for 90 s, at most once per 5 minutes. It is **off by default**: in the one case where a software reconnect was tried on a dead Wi-Fi data path it did not help.

## Motion

Majestic (the camera's video service) has a hardware motion detector, off by default. Enable it with this in `/etc/majestic.yaml` (a flash write; restart Majestic with `/etc/init.d/S95majestic restart`):

```
motionDetect:
  enabled: true
```

Majestic then serves Prometheus counters at `/metrics/motion`; with detection off it reports zeros and never rises. The daemon reads `md_rects_acc_total` (rectangles the detector reported inside the region of interest) from `127.0.0.1` once per second. Requests from the camera itself need no password (observed: the camera's own requests skip Majestic's authentication, while requests from the network get `401`). A counter that goes down means Majestic restarted and is treated as a new baseline, not as motion; a `401` page, an answer without the counter or a half-written line is ignored; if Majestic disappears while the sensor is ON, it still goes OFF after the hold time.

Observed on the unit (one camera, 2026-11-20): the counter rose from 0 to 148 and to 201 in two hand-waving tests, the load average did not change, and the Home Assistant entity followed. **Not known:** the false-alarm rate (shadows, light changes, the corridor outside), the effect of the default sensitivity and region of interest, behaviour over days and at night.

## Snapshot

**Why the camera pushes the picture instead of Home Assistant pulling it.** The camera's web interface (Majestic, port 80) has one administrator account, the root password: its `access.cgi` page changes the root password, and it offers a terminal (`console.cgi`), a file manager, the configuration API (`/api/v1/set`), firmware update and factory reset. There are no roles. A second account (the root password is also what RTSP and SSH use) would be the same administrator under another name, sent in clear text over HTTP. So nothing outside the camera should be given a credential for port 80. (Read from the CGI scripts and the web server's route list on the unit; the pages were fetched from the camera itself, no remote administrator action was tried.) Requests from the camera itself skip authentication (observed), so the daemon can fetch the picture locally and send it over the connection it already has to the broker. Home Assistant needs no route and no password for the camera.

On the Motion edge OFF to ON (not on every poll) the daemon requests `snapshot_path` from `127.0.0.1`, checks that the answer is `200` and that the body starts with the JPEG start marker and ends with the end marker (a half-read or an error page is never published), and publishes it retained to `doorview/<node>/snapshot`. At most one picture per `snapshot_cooldown` seconds; a picture whose edge is more than 10 s old (the broker was unreachable) is dropped. The picture is read into a static buffer and the MQTT header is written in front of it, so it is not copied; pictures above 24 KB are not published. At the default 480 by 270, quality 40, the picture was about 12 KB on the unit (640 by 360 at quality 30 gave about 16 KB, at the default quality 22 KB).

## How it works

It opens `/dev/kmsg` and parses the `doorview_control` and `doorview_power` lines the stage 3 network driver writes ([coprocessor](wifi-companion.md#control-frames-from-the-mcu)). Because it needs the `doorview_power` line, stage 3 replaces the stage 2 driver with a build that adds it; the button line the LCD service matches is unchanged. A single poll loop handles the kernel log, the socket and the timers; connecting is non-blocking. The motion poll is a short exchange on its own socket (bounded to 300 ms, stopped as soon as the line is complete), so a slow Majestic cannot stall the MQTT connection for long. The daemon pings the broker when it has heard nothing for half the keepalive, even while it is publishing: the broker acknowledges nothing the daemon publishes, so a daemon that publishes often would otherwise declare the broker dead (found by the motion tests).

Source: `firmware/userland/mqtt/` (`doorview-mqtt.c` is the logic; `sys-arm.c` is a raw-syscall layer for the camera; `sys-host.c` is a POSIX layer used only by the tests).

## Known limits

- Plain TCP, no TLS.
- No clean `offline` on stop.
- IPv4 literal only.
- Roughly 100 minutes of total stability observation exist for the interrupt-driven driver the daemon runs on top of; the daemon adds a TCP connection on top of that.
