# A faster first picture: the `first-snap` prototype

**State (2026-11-23): run on the unit from RAM, but it does not get past `GK_API_SYS_Init` yet** (see [first runs](#first-runs-on-the-unit-2026-11-23)). Nothing here is installed by any stage.

## The question

After a PIR wake-up the snapshot is the slowest step that is still ours to change. Majestic needs about 3 s from its start to the first picture at a cold start, and 1.33 s at a warm restart. Its resolution, slow shutter and frame rate change that by at most 0.12 s (observed on the unit, see [known limits](known-limits.md)). Majestic also starts things the camera does not need for that picture: its HTTP server, the stream encoders and the configuration parser. The difference between a cold start and a warm restart suggests that the vendor pipeline's first set-up costs most of the time, not Majestic itself. That is an assumption until it has been measured. `first-snap` measures it.

## What the program does

[`firmware/userland/capture/first-snap.c`](../firmware/userland/capture/first-snap.c) sets up only what one JPEG needs:

1. the buffers and the system;
2. the MIPI receiver and the sensor clock and reset;
3. VI;
4. the sensor library and the 3A libraries;
5. the ISP;
6. VPSS;
7. the ISP thread;
8. a JPEG channel.

It then writes the first N pictures to `/tmp/first-snap-<n>.jpg`. For every step and every picture it prints the time since boot (the clock of the kernel log, so the lines match `dmesg`) and the time since its own start. After every picture it also prints the ISP's exposure state: the mean luma, the histogram error, the exposure values and the ISO.

Each picture has a time. Its exposure values show from which frame on the picture is usable (the automatic exposure starts from a default and needs some frames to settle). Together the two give the answer.

- **Sources of the parameters.** The pipeline order and the structure fields follow OpenIPC's divinus streamer (MIT licence, its `hal/hisi/v4_hal.c` for the Hi3516EV200 family, which includes GK7205V200 and GK7202V300). The sensor values come from `/etc/sensors/gc2053_i2c_1080p.ini` in the OpenIPC root file system on the camera: two MIPI lanes (0 and 2), RAW10, 1920 × 1080 and RGGB. The sensor sits on I2C bus 0, which is also the sensor library's default bus.
- **Headers and libraries.** The headers are those of `OpenIPC/openhisilicon` at the pinned commit. The vendor libraries are linked as load-time dependencies, as Majestic links them (`readelf -d` of Majestic: `libgk_api`, `libgk_isp`, `libgk_ae`, `libgk_awb`, the audio libraries `libupvqe`, `libdnvqe` and `libvoice_engine`, `libldci`, `libdehaze`, `libdrc`, `libir_auto` and `libsecurec`); only the sensor library is opened with `dlopen`. Three uClibc symbols they use come from the compatibility library of stage 2, so the program runs with `LD_LIBRARY_PATH=/etc/doorview-lcd`. The vendor libraries are not in the repository.
- **Image tuning.** The noise profile `/etc/sensors/iq/gc2053.ini` is **not** loaded, so the pictures use the sensor library's default tuning. They can be noisier at night than Majestic's.
- **Initial exposure.** `-e <file>` hands the last exposure (the `state:` line of an earlier run) to the sensor library's `pfnSetInit` before the ISP starts. The automatic exposure can then start near the right value instead of from its default. Whether the GC2053 library uses these values is unknown.

```
first-snap [-n pictures] [-w width] [-h height] [-q quality] [-f fps] [-o prefix] [-e exposure-file]
defaults:  -n 5 -w 1280 -h 720 -q 55 -f 30 -o /tmp/first-snap
```

## Building

`tools/build.sh` builds it next to `vo-live-30` when `build/rootfs-libs/` holds the OpenIPC `libc.so` and the vendor libraries (`tools/extract-rootfs-libs.sh` extracts them from the flashed image). The output is `build/out/userland/first-snap`. Its hash is not in `firmware/EXPECTED-BUILDS.txt` because it has not run on a camera.

## How to measure it (needs the camera on the UART; RAM only)

This writes nothing to flash and needs no installer.

1. Upload the binary with `tools/upload-archive.py` (it lands in `/tmp/doorview-upload`).
2. Keep the camera awake: `touch /tmp/doorview-stay-awake`.
3. Stop Majestic: `killall majestic`, then wait until `pidof majestic` prints nothing.
4. Run `LD_LIBRARY_PATH=/etc/doorview-lcd /tmp/doorview-upload/first-snap -n 10` and keep its output.
5. Copy one or two pictures back to look at them. Then run it again with `-e` and a file that holds the `state:` line of the first run.
6. Start Majestic again (`/etc/init.d/S95majestic start`), or reboot.

What this measures is a **warm** start: Majestic has already set up the sensor and the vendor modules once since the boot. Compare it with Majestic's 1.33 s at a warm restart. A **cold** measurement means Majestic must not start at boot, which needs a changed start-up script on the overlay. That is a flash write and needs the owner's approval first. The alternative is a RAM-only rcS through the failsafe path, which is not worked out.

## First runs on the unit (2026-11-23)

Observed, warm (Majestic stopped with `killall`), from `/tmp`, nothing written to flash:

1. Opening the vendor libraries one by one with `dlopen` fails: musl reports unresolved symbols (`__fgetc_unlocked` in `libsecurec`, `AUDIO_UPVQE_Destroy` in `libgk_api`, `IO_READ16` in `libdehaze`). The libraries need each other in a cycle (`libgk_isp` and dehaze/drc/ldci) through relocations that musl does not defer. Linking them as load-time dependencies, as Majestic does, fixes this.
2. `GK_API_SYS_Exit`, `GK_API_VB_Exit`, `GK_API_VB_SetConfig` and `GK_API_VB_Init` return 0; **`GK_API_SYS_Init` then crashes** with a NULL dereference (fault address `0x10`) inside musl's `vfprintf`, called from code in the dynamic linker. Moving the program's own output off musl's stdio (it writes with `write(2)` now) and defining `printf`, `puts` and `fprintf` as Majestic does (Majestic exports its own `printf`, `puts` and `mmap`) did not change it.

Not known yet: which vendor call reaches `vfprintf` with a NULL stream, and what else Majestic does before `SYS_Init` (it exports `HI_MPI_SYS_SetReg` and links `libhi_mpi` too). The next step is to disassemble `GK_API_SYS_Init` in `libgk_api.so` around the call that fails. Majestic started again normally after every run.

## Risks

- **Bad parameters.** If a parameter is wrong (a MIPI or VI attribute, the I2C bus), the expected result is an error code at that step, or a `picture timeout` after 3 s. The program then tears the pipeline down so that Majestic can start again.
- **A hung SoC.** A wrong setting could also hang the SoC. A reboot or the power button recovers it; nothing persistent is touched.
- **Coprocessor.** The program sends no command to the Wi-Fi/battery coprocessor.

## What decides whether it is worth more work

- **If the first usable picture is not clearly earlier than Majestic's** (warm: 1.33 s, cold: about 3 s), the time is in the vendor pipeline, and Majestic stays.
- **If it is clearly earlier,** the next step is a program that hands the picture to the daemon. The daemon fetches it over HTTP from Majestic today, so this needs a local file or a socket instead. Majestic would then start later for the live view, or not at all on a PIR wake-up. That changes the daemon, the start-up scripts and the live view, so it would be a new stage with its own tests.
- **If `-e` shortens the time to a settled exposure,** the last exposure would have to survive the sleep. RAM is lost when the SoC is switched off, so it would go to the overlay. That costs a small flash write at every wake-up (wear), and it needs its own decision.
