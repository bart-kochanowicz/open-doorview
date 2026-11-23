# Night vision: IR-cut filter and IR LEDs

The camera has an IR-cut filter and IR LEDs, and both are switched by **one GPIO**. Majestic already contains the day/night logic; it only needs to be told the pin.

## Where the pin comes from

- The factory firmware keeps a small hardware table in `hardinfo.bin` (JFFS2 partition `0x5e0000`). Its `<GPIO>` block lists `IrCut1B` as `10_0x00000000_0_1`, next to `LcdEn` (`15_…_0_1`), `BlueLed` (`16_…_0_1`) and `SpeakerCtrl` (`17_…_0_0`). The notation is decimal bank and pin: `15` is GPIO1_5, which is Linux GPIO 13 (already used for the LCD backlight), so `10` is GPIO1_0, **Linux GPIO 8**. *Read from the factory firmware.*
- The factory board setup (`p2pcam.bin`, function at file offset `0x13b260`) writes pin-mux values for GPIO1_1, GPIO1_4, GPIO1_6 and GPIO1_7 and **does not touch GPIO1_0**, so the pad keeps its OpenIPC default (`0x120c0000` reads `0x1000`) and no pin-mux change is needed. *Read from the factory firmware; the OpenIPC value was observed on the unit.*

## What was observed on the unit (2026-11-21)

- Driving GPIO 8 high by hand (sysfs, RAM only) made the picture magenta, the typical sign of a retracted IR-cut filter, and the IR LEDs lit (seen through a phone camera). Low gave normal colours and the LEDs were off. So **high is night, low is day**, which is Majestic's default polarity for a single pin (no `irCutSingleInvert` needed).
- With `nightMode.irCutPin1: 8` in `/etc/majestic.yaml`, Majestic takes the pin (`set_gpio(8, 0)` by day). `GET /night/on` gave `Change mode to NIGHT`, the pin went high and the picture turned black and white and readable, with the night IQ profile loaded; `/night/off` went back.
- Majestic only switches by itself with `nightMode.lightMonitor: true` (the default is false: it then switches only while someone watches). With it on, covering the lens made it switch to night within about 15 s without any viewer.

## Configuration

```yaml
isp:
  slowShutter: medium
nightMode:
  autoNightGain: 16
  autoDayGain: 4
  autoNightDelay: 1
  monitorDelay: 1
  irCutPin1: 8
  lightMonitor: true
```

Write it to `/etc/majestic.yaml` (a flash write: two identical overlay reads first) and restart Majestic. Defaults that matter: `irCut` and `backlight` are `auto`, `switchBy` is `picture`, 15 s of darkness before night and 60 s of brightness before day. `slowShutter: medium` is explained under the noise profile below; the install guide's lighter video profile uses `disabled`, which keeps 5 fps for video.

## Noise profile for the GC2053 (installed 2026-11-21)

Majestic runs `/etc/sensors/iq/default.ini`, a link to `imx307.ini`, on this GC2053 camera, because it uses "the profile named after the sensor, or `default.ini` when there is none" and there is no `gc2053.ini`. The factory firmware's `Day_level0.xml` (partition `fs-c`; `sensor.cfg` and `hwcfg.ini` say `gc2053`) has an `NR` page with `Auto.FineStr`, `Auto.CoringWeight` and `Auto.CoarseStr`, 16 values per ISO step: the same fields as `FineStr`, `CoringWgt` and `CoarseStr_0..3` in Majestic's profile. The factory values are much stronger at high gain (`CoringWeight` 60 against 0, `FineStr` about 80 against 40 to 50). `tools/gc2053-iq.sed` replaces those twelve lines, in `[static_nr]` and in `[ir_static_nr]` (the section used at night); it is written for the `imx307.ini` whose SHA-256 is in its header. The result, `/etc/sensors/iq/gc2053.ini` (143,745 bytes, about 21 KB compressed in the JFFS2 overlay), is picked up by name; **deleting the file undoes it**. Majestic's log then says `IQ /etc/sensors/iq/gc2053.ini: …`.

Measured on the unit (observed), nobody moving in a nearly dark room, night mode forced, runs back to back (the first test used a RAM-only bind mount, then the file was installed):

| | motion rectangles per 10 s | picture at `qfactor=45` | sensor gain |
|---|---|---|---|
| `imx307` profile (before) | 636 | 276 KB | 22,528 |
| `gc2053` profile | 211, then 185 | 234, then 229 KB | 27,036 |
| `gc2053` and `slowShutter: medium` | 64 | 197 KB | 22,528 |
| `gc2053` and `slowShutter: high` | 152, then 94, 43, 29 (per 8 s) | 205 KB | 22,528 |

- `slowShutter` lengthens the exposure in the dark (40 ms to about 53 ms here) at a lower frame rate; `high` gave no longer exposure than `medium`, and the spread of the counts is large, so `medium` was kept. It costs video frame rate, which is irrelevant while the main stream is 1080p.
- A hand waved in front of the lens for 12 s with the final settings gave about 37 rectangles per second against about 13 per second without it: roughly **3 times the noise** (1.6 times before the profile).
- Daylight: a picture taken afterwards in a lit room has natural colours and good detail, no visible softening compared with the older daylight pictures (a visual comparison, at a different `qfactor`).

The daemon now has a threshold on the rate (`motion_min_rate`, `motion_window`, see the [MQTT guide](mqtt-home-assistant.md#motion)) and a delay for the picture (`snapshot_delay_ms`). The unit runs `motion_min_rate=20`, `motion_window=3`, `snapshot_delay_ms=1500` (2026-11-21), from `mqtt.conf`.

Measured with it on the unit (observed), a dark room, in the HA recorder:

- **Night mode with the IR LEDs on:** the counter gained about 0 to 4 rectangles per 3 s, and the Motion sensor stayed off for more than three minutes (it had been on, and went off about 10 s after night mode was forced). Two waves of a hand, 95 s apart, each turned Motion on; the pictures reached Home Assistant about 8 to 9 s after the edge (the 1.5 s delay plus about 5 s to send a 190 to 210 KB night picture).
- **Day mode in the same dark room (no IR, exposure up to about 485 ms with `slowShutter: medium`):** the counter gained about 30 per second, above the threshold, and the sensor was on for several minutes. This is the case that is left, because of the next point.

**The camera did not switch to night mode by itself in that dim room** (gain 38,000 to 45,000, not at its maximum; earlier, with `slowShutter: disabled` and a maximum gain, it also needed the lens covered completely). Majestic decides from the sensor's own exposure state, so in a room that is dark but not black it stays in day mode and the IR LEDs stay off. Whether a real doorway at night is dark enough is not known. `nightMode.switchBy` offers `clock`, `sun` and the `pictureNear…` variants (`nightFrom`, `dayFrom`, latitude and longitude); none was tried.


## Night mode right after a wake-up (2026-11-23)

Since the camera sleeps between events, every wake-up starts Majestic in day mode. With the defaults it went to night only when the exposure ran out completely (`autoNightGain` empty), and only after 15 s of darkness; the picture after a PIR wake-up is taken about 1 s after Majestic answers and the camera sleeps again 60 s later. **Observed on the unit:** in the dark the exposure sat at its maximum (485 ms) with a gain of 53x to 75x for 48 s, the IR pin stayed low, and the picture of the wake-up was dark and in colour.

`autoNightGain: 16` (night at 16x gain), `autoDayGain: 4` (day again at 4x or less), `autoNightDelay: 1` and `monitorDelay: 1` (seconds) make Majestic decide from the gain within its first second. **Observed on the unit:** tested first with a RAM-only bind mount of the file, then written to `/etc/majestic.yaml` after two identical overlay reads; after a Majestic restart in the dark the IR pin went high 3.1 s after the start and stayed high (27 s watched), and the picture was black and white and readable. The first picture of a wake-up still came before the switch (Majestic answers before it has measured the light); stage 13 makes the daemon wait for night mode (`night_wait_ms`, see the [install guide, step 18](install-guide.md#step-18-optional-stage-13-the-night-picture-after-a-wake-up)). The day threshold of 4x is a guess: the gain in daylight at the door was not measured, and the gain with the IR LEDs lit is lower than without them (Majestic checks day with the lamp down, `night_probe_*` in `/metrics`).

## Earlier problems (2026-11-21), kept for the record

Most of this no longer applies: since stage 7 the motion comes from the PIR and Majestic's video motion detector is off, so the noise of the picture in the dark cannot cause motion any more; since 2026-11-23 the camera goes to night by itself (above), and the picture is 960 × 540 at quality 55. What is still open is listed under [Still open](#still-open).

### Motion detection in the dark (measured 2026-11-21, observed on the unit)

Before the noise profile below was installed: in a nearly dark room (gain at its maximum) Majestic's hardware motion detector reports rectangles all the time, with nobody moving, in night mode and in forced day mode alike. Home Assistant's recorder shows the consequence: the Motion sensor was **on for almost eight minutes without a break** (16:50:27 to 16:57:54), so no OFF to ON edge, no picture and no notification could follow.

| `motionDetect.sensitivity` | rectangles per second, nobody moving |
|---|---|
| 3 (default) | about 85 |
| 1 | about 59 |
| 0 | about 38 |

A hand waved in front of the lens for 15 s at sensitivity 0 gave about 60 per second: only about 1.6 times the noise. So neither the sensitivity nor a rate threshold in the daemon separates movement from noise in that scene. The unit was left at the default 3, which is the setting verified in daylight.

What is left, none tried yet (the noise profile and `slowShutter` above are done):

- **Switch to night mode by the clock or the sun** (`nightMode.switchBy`) so that the IR LEDs are on at night whatever the picture looks like; not tried.
- **Use another trigger at night.** The front button already reaches Home Assistant as an event; taking a picture on a button press would not depend on the noise.
- **PIR (read from the factory firmware; not seen on the unit).** The factory firmware has a PIR path through the MCU: the message table in `p2pcam.bin` (file offset `0x537ee8`, entries of name, handler and id) lists `HI_SYSLINK_MSG_M2S_PIR_ALARM` with **id 4**, in a group of alarm messages (low battery 3, Wi-Fi 5, external power 6 and 7, key event 8), while the ring key is `0xA5` (the button we observe) and `0xA3` is `POWERINFO`; there are also PIR sensitivity get and set calls (`PDT_TEST_MCU_GetPIRSen`, `SetPIRSen`), a PIR wake-up reason and `support_pir = 1` in `hwcfg.ini`. There is no PIR pin in the GPIO table. Our driver logs every application message (`doorview_control: command=..`), and during hours of use, including hand waves in front of the lens, only `0xA2` and `0xA5` appeared, so the MCU does not send PIR alarms by itself. Making it do so probably needs a command to the MCU (enable and sensitivity), which is exactly what the documentation warns about: one such command silenced the UART and needed a power-button press. The message ids above also disagree by one with the documented `0xA2` PowerInfo (the table says `0xA3`), so the table may not be the wire numbering; the wire id of the PIR alarm is therefore **not established**.
- A region of interest (`motionDetect.roi`, `XxYxWxH`, empty means the whole frame) restricts where motion counts, so it can remove an unwanted zone but not noise inside the zone; it was not tried; a doorway at night, lit by the IR LEDs, may also be far less noisy than this dark room.
- The snapshot used to be taken at the instant of the edge: after the lens was uncovered it caught a nearly black frame while the exposure adapted, and at a door it may catch the person only partly in view. `snapshot_delay_ms=1500` is set now; whether 1.5 s is the right delay at a real door was not tried.

### Pictures

Night pictures are noisier and larger (215 to 326 KB at `qfactor=60` and 1920 × 1080 in that dim room) and took up to 7 s to send. The unit now requests `snapshot_path=/image.jpg?qfactor=45` from `mqtt.conf`; measured on the same dim scene: 228 KB at 60, 181 KB at 45, 164 KB at 40. The daemon refuses a picture above 320 KB.

## Still open

- **The day threshold** (`autoDayGain: 4`) is a guess: the gain in daylight at the door was not measured.
- **The night picture after a real wake-up** was seen once (2026-11-23): IR-lit, but still in colour with a violet cast, because Majestic switches the IR-cut filter and the LEDs before the picture settings; waiting for `picture_night` as well (in `/metrics/night`) would give the grey picture at the cost of a little more time.
- **The IR LEDs** stay on while the camera is awake at night; their power draw was not measured, and with the sleep the camera is awake only for short windows.
