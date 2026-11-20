# MQTT and Home Assistant

`doorview-mqtt` is a small daemon (11 KB, static ARM, no libc) that publishes the camera's battery, external power, button and uptime to an MQTT broker, with Home Assistant MQTT discovery so the entities appear on their own. It is stage 3 of the [install guide](install-guide.md#step-8-stage-3-mqtt-for-home-assistant).

**Status:** an earlier build of the daemon was run from RAM on a real camera against a temporary broker (discovery, a retained state from a real power frame, one event per real button press, OFF/ON on a real USB unplug and replug, uptime every 60 s, no reconnects over the run). Code review then found two defects (a write to a closed socket killed the daemon with SIGPIPE; a failed first publish after CONNACK made the receive loop read past its buffer). Both are fixed and the shipped binary was rebuilt; the rebuilt binary has run only in the host and Docker tests and under `qemu-user`, **not yet on a camera**. The persistent stage 3 install has not been done on any camera. The logic is covered by 49 tests against a real Mosquitto in Docker (`firmware/userland/mqtt/tests/run-tests.sh`).

## What it needs

- An MQTT **3.1.1** broker reachable from the camera on plain TCP, with a user and password. There is no TLS: the password crosses your network in clear text, so keep the camera and broker on a network you trust (the camera does have an mbedTLS library, but this client does not use it).
- The broker address must be an **IPv4 address**. The daemon has no DNS.
- The camera's user needs *write* access to `doorview/<node>/#` and `homeassistant/+/<node>/+/config`, and nothing else. An example Mosquitto ACL (as used in the tests; `front-door-camera` is the default node name):

  ```
  user home-assistant
  topic readwrite #

  user front-door-camera
  topic write doorview/front-door-camera/#
  topic write homeassistant/+/front-door-camera/+/config
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
node=front-door-camera
name=Front door camera
discovery=homeassistant
keepalive=60
wifi_watchdog=0
```

`configure.sh` rejects hostnames, a missing user or password, unknown keys, bad ports, over-long values and symlinks, and it prints nothing from the file. Without this file `S97doorview-mqtt` starts nothing, so installing the package is harmless until you configure it.

`wifi_watchdog=1` makes the daemon request a station reconnect when the broker has been unreachable for 3 minutes and no frame was received for 90 s, at most once per 5 minutes. It is **off by default**: in the one case where a software reconnect was tried on a dead Wi-Fi data path it did not help.

## How it works

It opens `/dev/kmsg` and parses the `doorview_control` and `doorview_power` lines the stage 3 network driver writes ([coprocessor](wifi-companion.md#control-frames-from-the-mcu)). Because it needs the `doorview_power` line, stage 3 replaces the stage 2 driver with a build that adds it; the button line the LCD service matches is unchanged. A single poll loop handles the kernel log, the socket and the timers; connecting is non-blocking.

Source: `firmware/userland/mqtt/` (`doorview-mqtt.c` is the logic; `sys-arm.c` is a raw-syscall layer for the camera; `sys-host.c` is a POSIX layer used only by the tests).

## Known limits

- Plain TCP, no TLS.
- No clean `offline` on stop.
- IPv4 literal only.
- Roughly 100 minutes of total stability observation exist for the interrupt-driven driver the daemon runs on top of; the daemon adds a TCP connection on top of that.
