# Known limits and open questions

Read this before trusting any part of the project.

## Scope of the evidence

- **One camera.** Everything was developed and tested on a single RH-PD10. Another unit, batch or firmware revision may differ (the board, the MCU firmware, the flash layout).
- **Days, not months.** The longest uninterrupted observation of the interrupt-driven driver is 47 minutes; about 100 minutes in total. Earlier failures appeared at random up to 31 minutes. Rare failures cannot be excluded.
- **The shipped `doorview-mqtt` was rebuilt twice on 2026-11-20.** The first rebuild (after code review: SIGPIPE handling and a receive-buffer fix, hash `d628a47c…`) ran on the camera for minutes and two reboots. The current build adds the motion sensor and a keepalive fix (hash `cadd0d5c…`, in `payload/`); it ran from RAM first and was then installed with stage 3 on the same day. Observed after that install and again after a reboot: the Motion entity went ON in Home Assistant when a hand was waved in front of the lens. Still only minutes to hours of runtime; not observed with this build: a long run, a broker outage on the camera. The SIGPIPE, receive-buffer and keepalive paths were exercised by the Docker suite (including an ASan/UBSan build) and under `qemu-user`.
- **Stage 1 and 3 installers are new.** The stage 1 installer was written for this repository and has been tested only on fixture trees (the unit received its stage 1 files through earlier scripts that did not survive in this form). The stage 3 installer was run on the unit on 2026-11-20 (install, `rollback.sh`, install again; the rollback restored the previous driver exactly). The stage 1 installer has still not run on a camera. Stage 2's payload was installed and verified on the unit; its installer script was hardened after review and has been run only by the fixture tests.
- **No restore of the factory firmware has ever been tested.** Two identical reads prove consistency, not that writing them back works.

## Things that are guesses

- The battery capacity scale. 99 and 100 were observed; percent is assumed. After the last reboot (2026-11-20) the MCU reported `status=1, usb=0, capacity=100` (on battery) in every PowerInfo frame for at least 3 minutes while the camera was connected to USB (confirmed by the owner); in earlier boots the frames showed `status=2, usb=1`. The cause is unknown, so Home Assistant's External power can be wrong for a while after a boot.
- The meaning of power status 2 (charging versus full).
- The panel controller and FPC pinout.
- That the Hi3861 identification of the coprocessor is exact.
- The cause of the early-boot resets. On 2026-11-20 **every one of three software reboots** (`reboot`) showed two resets before the third attempt reached the login prompt (three "System startup" banners, one "Welcome to OpenIPC" per capture; the resets come after "Starting mdev..." or earlier and before any Doorview hook). Whether a cold start (power removed) behaves the same was not tested. The camera was on a USB supply (ISDT Power 200H) throughout.
- Whether a PIR sensor is present and usable (the factory configuration says `support_pir=1`; nothing was tested).

## Not implemented

- Motion detection: the motion sensor is installed (daemon with `motion=1`, `motionDetect` enabled in `/etc/majestic.yaml`) and was seen to work after install and after a reboot, in hand-waving tests only. The false-alarm rate (shadows, light changes, the corridor), sensitivity, region of interest and night behaviour were never examined. Person detection does not exist.
- A default route: stages 1 and 2 set only the on-link route, so the camera cannot reach another subnet (observed 2026-11-20: `nc` to a broker in another subnet failed with "Network unreachable" and succeeded after `ip route add default via <router>` in RAM). Stage 3 adds it from `gateway=` in `mqtt.conf`. The first on-camera boot of that path failed: BusyBox `ip route show default` prints the whole routing table, so the first version of `S97doorview-mqtt` concluded a default route existed. It was fixed (it now looks for a `default` line) and the tests' `ip` stand-in now behaves like BusyBox; the fixed hook then added `default via <router>` by itself on the next boot (observed 2026-11-20).
- DHCP, automatic Wi-Fi reconnect (an optional watchdog exists, off, and its recovery step is unproven), WPA3, open networks, 5 GHz, SSIDs or passphrases over 31 bytes.
- Signal strength and access-point information (the factory command exists; it was never sent because commands to the MCU are risky).
- TLS for MQTT.
- Audio, the speaker and microphone, the IR cut filter and IR LEDs, the PIR, the battery fuel gauge beyond the MCU's value.
- Person detection. The SoC has one core, about 27 MB of RAM for Linux and no neural accelerator, so classification would have to run elsewhere with the camera only triggering and sending a frame.
- Over-the-air update, and anything that survives a re-flash.

## Gaps in what is recorded

- **The first OpenIPC flash.** The repository does not record the command sequence used. See [openipc-flash.md](openipc-flash.md).
- **`syslink_bg.ko`.** The binary on the unit (SHA-256 `a21e588b...`, 6,048 bytes) was built from an earlier revision of `syslink_bg.c` that was not kept. The source in `firmware/kernel/syslink-handshake/` is the later revision, which adds a `resume_connected` parameter and builds to a different file (`9a0567e0...`). The shipped binary is the one that ran for days; the later source has only been run from RAM. Consequence: the fallback in `S41doorview-network` that restores the heartbeat driver passes `resume_connected=1`, which the shipped (older) binary does not accept, so **that last-resort fallback would fail to load** on a unit with the shipped binary. It only matters when both network drivers fail to start.
- **`button-preview`, `vo-live-30`, `libuclibc-compat.so`.** Rebuilds are not bit-identical to the tested binaries; see [building.md](building.md).
- **Wi-Fi from a cold neighbour cache** with a second client was not retested systematically after the interrupt driver was introduced.

## Third-party material

- `vo.ko` is a proprietary vendor module from OpenIPC's firmware repository. It is downloaded, never redistributed here.
- `libuclibc-compat.so` is built from OpenIPC's `uclibc-compat` package (MIT).
- The kernel modules declare `MODULE_LICENSE("GPL")`.
- This repository has **no licence file yet.** Add one before publishing (the kernel modules need to remain GPL-compatible).
- Factory firmware, flash dumps and extracted factory files are not included and must not be published.
