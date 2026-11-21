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

- **Motion detection in the dark.** In a nearly dark room Majestic's hardware motion detector (`sensitivity: 3`) fired about 85 times a second in night mode and about 105 times a second in forced day mode, with nobody moving: sensor noise at high gain, not the IR LEDs. The daemon's Motion sensor is then permanently ON, so no OFF to ON edge, no picture and no notification. Lowering `motionDetect.sensitivity` (0 to 8) or a region of interest is the obvious next step; neither was tried. Scene brightness in the test was far lower than a lit doorway is likely to be.
- Night pictures are noisier and larger (215 to 326 KB at `qfactor` 50 and 1920 × 1080 in that dim room) and took up to 7 s to send. The daemon's limit is 320 KB, so a noisier picture would be refused; lowering the quality in `snapshot_path` (for example `qfactor=40`) is the setting to try.
- The notification at night was not confirmed: the owner got none after one wave, which is consistent with the stuck Motion sensor above, but the Home Assistant side could not be read from that computer at the time.
- The IR LEDs stay on for the whole night; power draw and heat were not measured.
