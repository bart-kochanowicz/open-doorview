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
nightMode:
  irCutPin1: 8
  lightMonitor: true
```

Write it to `/etc/majestic.yaml` (a flash write: two identical overlay reads first) and restart Majestic. Defaults that matter: `irCut` and `backlight` are `auto`, `switchBy` is `picture`, 15 s of darkness before night and 60 s of brightness before day.

## Not solved

### Motion detection in the dark (measured 2026-11-21, observed on the unit)

In a nearly dark room (gain at its maximum) Majestic's hardware motion detector reports rectangles all the time, with nobody moving, in night mode and in forced day mode alike. Home Assistant's recorder shows the consequence: the Motion sensor was **on for almost eight minutes without a break** (16:50:27 to 16:57:54), so no OFF to ON edge, no picture and no notification could follow.

| `motionDetect.sensitivity` | rectangles per second, nobody moving |
|---|---|
| 3 (default) | about 85 |
| 1 | about 59 |
| 0 | about 38 |

A hand waved in front of the lens for 15 s at sensitivity 0 gave about 60 per second: only about 1.6 times the noise. So neither the sensitivity nor a rate threshold in the daemon separates movement from noise in that scene. The unit was left at the default 3, which is the setting verified in daylight.

Likely causes and ways forward, none tried yet:

- **The ISP noise profile is for another sensor, and fixing it helps a lot (measured, RAM only).** `/etc/sensors/iq/default.ini` is a link to `imx307.ini`; Majestic uses "the profile named after the sensor, or `default.ini` when there is none", and there is no `gc2053.ini`. The factory firmware's `Day_level0.xml` (partition `fs-c`) has an `NR` page for the GC2053 (`sensor.cfg` and `hwcfg.ini` say `gc2053`) with `Auto.FineStr`, `Auto.CoringWeight` and `Auto.CoarseStr`, 16 values per ISO step: the same fields as `FineStr`, `CoringWgt` and `CoarseStr_0..3` in Majestic's profile. The factory values are much stronger at high gain (`CoringWeight` 60 against 0, `FineStr` about 80 against 40 to 50). A copy of `imx307.ini` with these twelve lines replaced, in `[static_nr]` and in `[ir_static_nr]` (the section used at night), was bind-mounted over `imx307.ini` for the test and removed again. Same scene, night mode forced, both runs back to back:

  | | imx307 profile (now) | factory NR arrays |
  |---|---|---|
  | motion rectangles per 10 s, nobody moving | 636 | 211 |
  | picture at `qfactor=45` | 276 KB | 234 KB |
  | sensor gain during the run | 22,528 | 27,036 |

  Not tested: the effect on daylight sharpness (the factory FineStr is higher also at low ISO), the 3DNR tables (the factory has per-ISO files for the GC2053 in `fs-c`; the profile has them disabled in the static section), the motion detector with a real movement, and installing the file. A persistent install would be `/etc/sensors/iq/gc2053.ini` (about 21 KB compressed; 260 KB free in the overlay), picked up by name; removing the file undoes it.
- **Use another trigger at night.** The front button already reaches Home Assistant as an event; taking a picture on a button press would not depend on the noise.
- **PIR (read from the factory firmware; not seen on the unit).** The factory firmware has a PIR path through the MCU: the message table in `p2pcam.bin` (file offset `0x537ee8`, entries of name, handler and id) lists `HI_SYSLINK_MSG_M2S_PIR_ALARM` with **id 4**, in a group of alarm messages (low battery 3, Wi-Fi 5, external power 6 and 7, key event 8), while the ring key is `0xA5` (the button we observe) and `0xA3` is `POWERINFO`; there are also PIR sensitivity get and set calls (`PDT_TEST_MCU_GetPIRSen`, `SetPIRSen`), a PIR wake-up reason and `support_pir = 1` in `hwcfg.ini`. There is no PIR pin in the GPIO table. Our driver logs every application message (`doorview_control: command=..`), and during hours of use, including hand waves in front of the lens, only `0xA2` and `0xA5` appeared, so the MCU does not send PIR alarms by itself. Making it do so probably needs a command to the MCU (enable and sensitivity), which is exactly what the documentation warns about: one such command silenced the UART and needed a power-button press. The message ids above also disagree by one with the documented `0xA2` PowerInfo (the table says `0xA3`), so the table may not be the wire numbering; the wire id of the PIR alarm is therefore **not established**.
- A region of interest (`motionDetect.roi`, `XxYxWxH`, empty means the whole frame) restricts where motion counts, so it can remove an unwanted zone but not noise inside the zone; it was not tried; a doorway at night, lit by the IR LEDs, may also be far less noisy than this dark room.
- The snapshot is taken at the instant of the edge. After the lens was uncovered it caught a nearly black frame while the exposure adapted, and at a door it may catch the person only partly in view. A delay of one to two seconds is a change in the daemon.

### Pictures

Night pictures are noisier and larger (215 to 326 KB at `qfactor=60` and 1920 × 1080 in that dim room) and took up to 7 s to send. The unit now requests `snapshot_path=/image.jpg?qfactor=45` from `mqtt.conf`; measured on the same dim scene: 228 KB at 60, 181 KB at 45, 164 KB at 40. The daemon refuses a picture above 320 KB.

### Other

- The night notification was exercised once (the notification automation ran at 16:50 and 16:58, with a 215 KB and a nearly black 39 KB picture); a clean test, with the lens uncovered and more than a minute of waiting before the wave, was not done.
- `isp.slowShutter` is `disabled` here (to keep 5 fps for video). Majestic says a longer exposure in the dark gives a brighter, less noisy picture at a lower frame rate; since the 1080p video is not usable anyway, this is another lever for night noise, not tried.
- The IR LEDs stay on for the whole night; power draw and heat were not measured.
