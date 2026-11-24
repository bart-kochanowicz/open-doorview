# Known limits and open questions

Read this before trusting any part of the project. It says what is true now; the dated observations behind it, with every measurement, are in the [work log](log.md).

## Scope of the evidence

- **One camera.** Everything was developed and tested on a single RH-PD10. Another unit, batch or firmware revision may differ (the board, the MCU firmware, the flash layout).
- **Days, not months.** The interrupt-driven driver ran 8 hours without a stall once, but the overnight run of 2026-11-22 showed **three data-path stalls in 11.5 hours** (see [the stalls](wifi-companion.md#the-data-path-stalls-of-2026-11-22)), and another one happened on 2026-11-23. The daemon's `wifi_reboot` restarts the camera after a stall; the cause of the stalls is unknown. Rare failures cannot be excluded.
- **What ran on the camera.** Every binary in a `payload/` directory ran on the unit, and the installers of stages 3 to 13 were run there. The stage 1 installer has only run on fixture trees (the unit got its stage 1 files from earlier scripts), and the stage 2 installer was hardened after review and has only run on fixture trees too.
- **No restore of the factory firmware has ever been tested.** Two identical reads prove consistency, not that writing them back works.

## Things that are guesses

- **The battery capacity scale.** The percentage follows the battery voltage (the coprocessor log suggests raw 458 empty, 475 low, 558 full; see [the factory firmware](factory-firmware.md#battery-scale-from-the-coprocessor-log)). A reading under load (the screen on) or on the charger is not the charge state, and after a boot the External power entity can be wrong for a few minutes.
- The meaning of power status 2 (charging versus full).
- The panel controller and FPC pinout.
- That the Hi3861 identification of the coprocessor is exact.
- **The early-boot resets after a software reboot.** The first boot after `reboot` resets itself about 3 s after "Starting mdev..."; the second stops in U-Boot's failsafe mode (boot limit exceeded) until the coprocessor resets the SoC about 70 s later; the third succeeds, so a software reboot costs about 85 s. A start by the coprocessor (a wake-up) does not have them. The cause of the first reset is unknown; a hardware watchdog left armed by the previous run is a hypothesis.
- **Unexplained `poweron` wake-ups.** On 2026-11-24, during the network wake-up tests, the camera started twice with the reason `poweron` without anyone touching it (once while awake, once at the moment its RTC timer was due). In one network wake-up the coprocessor logged `syslink beatheart error, reboot camera now!` 10 s after the link came up and restarted the SoC with `poweron`; whether the other two were the same is not known.
- **The PIR range.** The factory app sends the sensitivity as 1, 3 or 5; on the unit level 1 needed a hand about 5 cm from the lens, level 3 saw a person about 1 m away, level 5 (installed) reacted to every walk into the picture. The range at level 5, the field of view, the cool-down between alarms and the false alarms are not measured.
- **The day threshold of the night mode** (`autoDayGain: 4`): the gain in daylight at the door was not measured, so the camera could stay in night mode on a dull day. In daylight the wake-up picture may wait up to about 1 s until Majestic has measured the light (not measured).

## Limits of what works

- **Start-up time** (measured on 2026-11-23, before stage 13): from the U-Boot banner of a PIR wake-up, the broker at 5.6 s, Majestic at 6.1 s, the picture at 10.2 s and the person alert in Home Assistant at 11.8 s. In the dark the picture now waits for night mode (about 1 to 3 s after Majestic answers, observed). What is left is mostly fixed: U-Boot 1.6 s, about 1 s before the kernel's clock starts, OpenIPC's `/init` 0.9 s, the vendor video modules 1.2 to 1.7 s, and Majestic about 3 s from its start to the first picture (1.33 s at a warm restart). A program of our own for the first picture ([first-snap](first-snap.md)) crashes in the vendor library so far.
- **Sleep.** The camera sleeps after 60 s without activity; while it sleeps, its Home Assistant entities are unavailable (Home Assistant keeps the last battery value in a template sensor). A press of the front button that wakes the camera is consumed by the coprocessor; stage 11 starts the LCD preview after such a wake-up, but that has not been checked on the camera yet.
- **Battery life in sleep mode is not measured.** Without sleep it was 15 to 18 hours.
- **Snapshot.** 960 × 540 at quality 55 (about 48 KB, about 1 s over the Wi-Fi). Sending a picture blocks the daemon's loop for up to 5 s. The broker's camera ACL has no `homeassistant/image/…` line, so the image discovery message is dropped there; Home Assistant declares the `image` entity by hand.
- **Motion** comes only from the PIR (stage 7); Majestic's video motion detector is off. Missed visitors and false wake-ups over days are not measured.
- **Night pictures.** Majestic switches to night from the sensor gain within about 3 s of its start; the first picture of a wake-up waits for it (stage 13). Observed after a real PIR wake-up in the dark: IR-lit, the person clearly visible, still in colour with a violet cast because Majestic moves the IR-cut filter and lights the LEDs before it switches the picture to grey ([night vision](night-vision.md)).
- **Person detection** runs on the server (two detectors beside Home Assistant), not on the camera: the SoC has one core, about 27 MB of RAM and no neural accelerator. The sample of real visitors is small, so the recall at the door, in the dark or far from the lens is not measured. The person alert is the only phone notification.
- **Live view** (a slide show of 640 × 360 pictures on demand): about 1.9 pictures per second, only while the camera is awake. Not measured during a night snapshot or a Wi-Fi stall.
- **The camera's web interface is an administrator interface.** One account (root), no roles, a web terminal, configuration API, firmware update and factory reset, over HTTP in clear text; RTSP and SSH use the same root password. Anyone who can reach port 80 and knows the password has a root shell. Keep the camera's VLAN closed to everything except what needs it, use a long unique root password (the OpenIPC default is `12345`), and do not give Home Assistant or anything else a credential for it. The snapshot feature exists so that nothing has to. On the unit the web panel is hidden (install guide, step 14).

## Not implemented

- DHCP, automatic Wi-Fi reconnect (an optional watchdog exists, off, and its recovery step is unproven), WPA3, open networks, 5 GHz, SSIDs or passphrases over 31 bytes. Stages 1 and 2 set only the on-link route; stage 3 adds the default route from `gateway=` in `mqtt.conf`.
- Signal strength and access-point information (the factory command exists; it was never sent because new commands to the coprocessor are risky).
- TLS for MQTT.
- **Waking the camera from Home Assistant.** The coprocessor can hold a connection to a server while the camera sleeps and wake it on a 6-byte pattern; this worked from RAM on 2026-11-24 (7.5 to 8.8 s from the pattern to the broker, or 21.5 to 24 s when the coprocessor resets the first boot, which it did in 4 of 7 runs), but no stage ships it, and its battery cost and that reset are not understood ([waking from the network](remote-wake.md)).
- Audio, the speaker and microphone, the battery fuel gauge beyond the coprocessor's value.
- Over-the-air update, and anything that survives a re-flash.

## Gaps in what is recorded

- **The first OpenIPC flash.** The repository does not record the command sequence used. See [openipc-flash.md](openipc-flash.md).
- **`syslink_bg.ko`.** The binary on the unit (SHA-256 `a21e588b...`, 6,048 bytes) was built from an earlier revision of `syslink_bg.c` that was not kept. The source in `firmware/kernel/syslink-handshake/` is the later revision, which adds a `resume_connected` parameter and builds to a different file (`9a0567e0...`). The shipped binary is the one that ran for days; the later source has only been run from RAM. Consequence: the fallback in `S41doorview-network` that restores the heartbeat driver passes `resume_connected=1`, which the shipped (older) binary does not accept, so **that last-resort fallback would fail to load** on a unit with the shipped binary. It only matters when both network drivers fail to start.
- **`button-preview`, `vo-live-30`, `libuclibc-compat.so`.** Rebuilds are not bit-identical to the tested binaries; see [building.md](building.md).
- **The sources of earlier stage binaries** are not in the tree any more; `tools/build.sh` takes them from git history (`OLD_SOURCES_COMMIT` in `tools/pins.sh`), so a shallow clone cannot rebuild them.
- **Wi-Fi from a cold neighbour cache** with a second client was not retested systematically after the interrupt driver was introduced.

## Third-party material

- `vo.ko` is a proprietary vendor module from OpenIPC's firmware repository. It is downloaded, never redistributed here.
- `libuclibc-compat.so` is built from OpenIPC's `uclibc-compat` package (MIT).
- The kernel modules declare `MODULE_LICENSE("GPL")`.
- This repository has **no licence file yet.** Add one before publishing (the kernel modules need to remain GPL-compatible).
- Factory firmware, flash dumps and extracted factory files are not included and must not be published.
