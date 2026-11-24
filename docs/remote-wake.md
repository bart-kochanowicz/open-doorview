# Waking the camera from the network

The factory firmware's cloud can wake the sleeping camera for a live view. The same mechanism works without the cloud: while the SoC is off, the Wi-Fi coprocessor keeps a TCP connection to a server of our own, and an agreed 6-byte pattern sent on that connection makes it power the SoC on with the wake-up reason `wifi`. **Observed on the unit on 2026-11-24, and installed there as stage 14 ([install guide, step 19](install-guide.md#step-19-optional-stage-14-the-wake-up-from-the-network)): the daemon arms the keep-alive before every standby, and ten wake-ups from the server in a row each brought the camera to the broker in 7.5 to 8.7 s.** Home Assistant triggers it: Start in the live view of the front-door panel woke the sleeping camera, which reached the broker 8 s later (observed once, the same day). The dated record, with every attempt that did not work, is in the [work log](log.md#waking-from-the-network-2026-11-24).

Evidence levels as elsewhere: **observed** (on the unit), **from the factory firmware** (read from the RTOS image), **from the coprocessor log** (its own UART, read passively), **assumption**.

## How it works

Before a standby the SoC gives the coprocessor four things on the Wi-Fi channel (`0x9a`), then starts the usual standby (`8a:77 07`, `9a:03`, answer `8a:61`; see [the factory firmware](factory-firmware.md#the-factory-power-cycle-from-the-factory-firmware)):

| Order | Command | Payload | What the coprocessor does (from its log) |
|---|---|---|---|
| 1 | `9a:07` | 304 bytes: authentication on/off, type, length, data | `received soc auth request msg. isAuth = 0, AuthType = 0`: no authentication |
| 2 | `9a:2c` | 261 bytes: the wake-up pattern | `net pattern enalbe: yes` |
| 3 | `9a:30` | 293 bytes: the server, the interval and the keep-alive packet | `addr:10.0.70.202, serverPort:7967`, `line = 1, lineThreshold = 1, interval = 30` |
| 4 | `9a:05` | none | starts the keep-alive: `connect SUCCESS !!!`, `AuthType = 0`, `keepalive success!` |

After the standby the coprocessor logs `--system slept,curState:KeepAlive--` and enters deep sleep with its RTC timer. It then sends the keep-alive packet at every interval (observed: every 30 s, as set). Data from the server is read in **6-byte chunks** (`KEEPALIVE_RecvLinePacket ... [6]`) and each chunk is compared with the pattern (`isWakeMatch`). A match powers the SoC on:

```
KEEPALIVE_WakeupFilterPacketCb packet =  packetlen = 6
PDT_STANDBY_SubscriberCb: received HI_EVENT_WIFI_WAKEUP event
PDT_SYSTEM_GetWakeupReason: wakeupMode:2, wakeupReason:4
PDT_SYSTEM_FillBootInfo: begin to send wakup reason:wifi, len:5 to camera ...
```

When the SoC is on, the coprocessor stops the keep-alive and closes the connection (`WiFiCtrl: stop keepalive`), so the keep-alive must be armed again before every standby, as the factory firmware does. While a keep-alive runs and the SoC is on, the coprocessor owns the camera's IP address: Linux loses its connections until `9a:04` and a station reconnect (observed).

## The payloads

**`9a:30`, the servers (293 bytes; observed working with one server):**

| Offset | Size | Meaning |
|---|---|---|
| 0 | 1 | 1 = keep-alive on |
| 1 | 1 | number of servers, 1 to 4 |
| 2 | 1 | wake line threshold (the factory firmware: `servers / 2 + 1`, so 1 for one server) |
| 3 | 2 | interval in seconds, little endian (the factory firmware: 60) |
| 5 + 72 × i | 1 | server *i* enabled |
| 6 + 72 × i | 1 | length of its keep-alive packet, up to 64 |
| 7 + 72 × i | 2 | port, little endian |
| 9 + 72 × i | 4 | IPv4 address, network order |
| 13 + 72 × i | 64 | the keep-alive packet (the coprocessor log calls it the keep-alive filter) |

**`9a:2c`, the wake-up pattern (261 bytes):** byte 0 = 1 (on), then four entries of 64 pattern bytes and a length byte (entry *i*: bytes `1 + 65 × i` to `64 + 65 × i`, length at `65 + 65 × i`). The factory firmware writes the same pattern into all four entries. **The coprocessor uses the fourth entry** (pattern at bytes 196 to 201, length at byte 260; observed: a probe with a different value in every byte made it report `g_wakeupAttr.filterLen = 53`, the value of byte 260, and a pattern only in the first entry left the length at 0). Because the server's data is read 6 bytes at a time, **the pattern is 6 bytes**: a longer one never matched, a 6-byte one did.

**`9a:07`, authentication (304 bytes):** byte 0 = authentication on/off, byte 1 = type (0 none, 1 "ycc", 2 "tange", 3 Tuya), bytes 2 and 3 = data length, then up to 300 bytes. The factory firmware always sends type 3 with a Tuya signature; the coprocessor then forwards the server's challenge to the SoC (message `0x07`), the SoC answers with `9a:08` (302 bytes) and gets the result as message `0x08`. With all 304 bytes 0 no exchange happens. Sending `9a:07` is not required for the keep-alive itself (it ran without it), and in the run that woke the camera it was sent.

## What was measured

- From the server sending the pattern to the U-Boot banner: about 2 s; the coprocessor reads the pattern about 1 s after it was sent, not at the next keep-alive.
- **To the camera on the broker: 7.5 to 8.7 s** with stage 14 (ten in a row, one clean boot each; one more run gave 4.3 s, probably because the camera was already starting for another reason).
- **The reset of the first boot, and its fix.** Before stage 14 the coprocessor reset the first boot after a network wake-up in more than half of the runs (`syslink beatheart error, reboot camera now!` about 10 s after the link came up) and only the second boot (reason `poweron`) worked, 21.5 to 24 s in all. A login into such a first boot before the reset showed why: the network driver's SDIO setup (`sdio_enable_func`, which waits for the function to report ready) failed right after the handshake driver handed over, and the driver gave up without a message, so no heartbeat ever reached the coprocessor. The coprocessor is still closing its keep-alive at that moment. Loading the driver again by hand 2 s later saved that boot. Since stage 14 the driver tries the setup up to 15 times, 200 ms apart, and logs each failure (`syslink_sdio: init attempt ... failed`); with it no reset was seen in ten wake-ups.
- A server that closes the connection does not wake the camera (no `dropline` wake-up in four closes); the coprocessor reconnects about every 90 s. A server that cannot be reached at all made it give up after a few attempts until the next standby (observed once).
- The battery cost of the keep-alive is not measured. The coprocessor wakes its radio at every interval to send the packet.
- On a network wake-up the coprocessor closes the PIR (`HI_PIRMNG_ClosePir`); the daemon switches it on again before every standby.

## The relay

The server end runs next to the broker in the homelab (`doorview-wake`, TCP 7967 on the broker's address; the firewall and the Cilium policy let only the camera's address reach it). It follows the camera's `live/set` topic on a listener of the broker that only the pod can reach and where anonymous clients may only read that topic. A non-retained `ON` while the camera holds its keep-alive connection makes the relay send the pattern and close the connection, at most once per 30 s and 20 times an hour: a wake-up costs a boot, the live view and at least `sleep_after` seconds awake. A retained `ON` is ignored, so a stale command cannot wake the camera. The pattern is in a Secret of the broker, never in clear in the homelab repository. The front-door panel keeps Start enabled while the camera is offline, so Start publishes that `ON`. Kubernetes probes the relay on a port of its own (7969), not on the camera port, so that its checks are never counted as camera connections. For tests the pod-local control port (7968) takes `wake` and `status`.

## What is still missing

1. The battery cost, measured over days against the sleep without the keep-alive.
2. More wake-ups from Home Assistant with the camera mounted at the door (one so far, on the bench), where the Wi-Fi signal is different.
3. The two `poweron` wake-ups of 2026-11-24 that nobody caused (possibly the same failed SDIO setup after a wake-up).

Every new coprocessor command needs a warning to the owner first; these five (`9a:04`, `05`, `07` with zeros, `2c`, `30`) were sent on 2026-11-24 with the owner's approval and silenced nothing.
