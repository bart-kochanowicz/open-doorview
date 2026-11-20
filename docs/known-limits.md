# Known limits and open questions

Read this before trusting any part of the project.

## Scope of the evidence

- **One camera.** Everything was developed and tested on a single RH-PD10. Another unit, batch or firmware revision may differ (the board, the MCU firmware, the flash layout).
- **Days, not months.** The longest uninterrupted observation of the interrupt-driven driver is 47 minutes; about 100 minutes in total. Earlier failures appeared at random up to 31 minutes. Rare failures cannot be excluded.
- **The shipped `doorview-mqtt` was rebuilt after code review** (SIGPIPE handling and a receive-buffer fix) and has not run on a camera since. It was exercised by the Docker suite (including an ASan/UBSan build against a broker that drops the connection) and, as the real freestanding ARM binary, under `qemu-user`, where the previous build died with SIGPIPE and the new one reconnects.
- **Stage 1 and 3 installers are new.** The stage 1 installer was written for this repository and has been tested only on fixture trees (the unit received its stage 1 files through earlier scripts that did not survive in this form). Stage 3 has never been installed persistently. Stage 2's payload was installed and verified on the unit; its installer script was hardened after review and has been run only by the fixture tests.
- **No restore of the factory firmware has ever been tested.** Two identical reads prove consistency, not that writing them back works.

## Things that are guesses

- The battery capacity scale. Only 99 was ever observed; percent is assumed.
- The meaning of power status 2 (charging versus full).
- The panel controller and FPC pinout.
- That the Hi3861 identification of the coprocessor is exact.
- The cause of the occasional early-boot restart (seen again on 2026-11-20, once, after "Starting mdev..." and before any Doorview hook; the next boot completed).
- Whether a PIR sensor is present and usable (the factory configuration says `support_pir=1`; nothing was tested).

## Not implemented

- A default route: stages 1 and 2 set only the on-link route, so the camera cannot reach another subnet (observed 2026-11-20: `nc` to a broker in another subnet failed with "Network unreachable" and succeeded after `ip route add default via <router>` in RAM). Stage 3 adds it from `gateway=` in `mqtt.conf`. The first on-camera boot of that path failed: BusyBox `ip route show default` prints the whole routing table, so the first version of `S97doorview-mqtt` concluded a default route existed. It was fixed (it now looks for a `default` line) and the tests' `ip` stand-in now behaves like BusyBox; the fixed hook has not yet run at boot on a camera.
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
