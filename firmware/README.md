# Firmware

Everything that runs on the camera, in install order. Each stage is a self-contained package: an installer, an exact rollback, the payload files and tests. Read the [install guide](../docs/install-guide.md) first; this page is the map.

```
firmware/
  stage1-wifi/    S39 handshake, SDIO modules, S41 Wi-Fi start-up, configure.sh for the credentials
  stage2-lcd/     interrupt-driven SDIO driver, S41 that prefers it, LCD + button service
  stage3-mqtt/    MQTT daemon, S97 hook, driver that also logs power frames, configure.sh for the broker
  kernel/         source of every kernel module (one directory per module, built out of tree)
  userland/
    lcd/          vo-live-30.c and button-preview.c (what stage 2 installs)
    mqtt/         doorview-mqtt.c, its two platform layers and its tests
  EXPECTED-BUILDS.txt   hashes of the binaries that were tested
```

## The stages and what they put on the camera

| Stage | Installs | Replaces | Requires |
|---|---|---|---|
| 1 `stage1-wifi` | `/etc/init.d/S39doorview`, `/etc/init.d/S41doorview-network`, `/etc/doorview/{syslink_poll.ko,syslink_bg.ko,syslink_net.ko}`; `configure.sh` adds `/etc/doorview/{station.hex,address,mac}` | nothing | a fresh OpenIPC overlay |
| 2 `stage2-lcd` | `/etc/init.d/S96doorview-lcd`, `/etc/doorview/syslink_net_irq.ko`, `/etc/doorview-lcd/*` | `S41doorview-network` (the old one is kept as `/etc/doorview/S41doorview-network.previous`) | stage 1, exactly |
| 3 `stage3-mqtt` | `/etc/init.d/S97doorview-mqtt`, `/etc/doorview/doorview-mqtt`; `configure.sh` adds `/etc/doorview/mqtt.conf` | `/etc/doorview/syslink_net_irq.ko` (the old one is kept as `syslink_net_irq.ko.previous`) | stage 2, exactly |

Not touched by any stage: the bootloader, its environment, the kernel, the factory identity and MAC (the MAC is only *read* from your backup and written to `/etc/doorview/mac`), and `/etc/majestic.yaml` (optional, by hand).

The boot order is by file name: `S39` handshake, `S41` network, `S95majestic` (OpenIPC's video server), `S96` LCD service (starts itself in the background after 20 s), `S97` MQTT daemon.

## Properties every installer has

- It checks that the writable overlay is the jffs2 partition `/dev/mtdblock5` and that nothing masks the target directories, and refuses otherwise.
- It refuses to overwrite any existing file, and (stages 2 and 3) to replace any file whose hash is not the tested one.
- It verifies every staged file against `SHA256SUMS` before it changes anything, copies through temporary files, verifies each copy with `cmp`, and puts the boot hooks in last so a hook never exists without what it needs.
- If any step fails it restores the exact previous tree itself.
- `rollback.sh` restores the previous state and refuses if a file was changed since.
- It prints one `..._INSTALLED` marker on success and nothing sensitive at any time.
- Every installer and rollback is a flash write. Take an overlay backup first.

## The init scripts

| File | Behaviour |
|---|---|
| `S39doorview` | loads `syslink_poll.ko bit_us=12`, waits for the SDIO device, retries up to ten times, then loads `syslink_bg.ko` |
| `S41doorview-network` (stage 2 version) | waits for the handshake, unloads `syslink_bg`, loads `syslink_net_irq.ko` (IRQ GPIO 36, 100 ms fallback poll) and falls back to the polling `syslink_net.ko`, then to the heartbeat driver; sets the MAC, MTU 700, the address and brings `dv0` up; queues the station connection from `station.hex`. Does nothing if the Wi-Fi configuration files are missing |
| `S96doorview-lcd` | starts `/etc/doorview-lcd/service` 20 s after boot, in the background; `stop`, `restart`, `status` pass through |
| `S97doorview-mqtt` | starts `doorview-mqtt` only if `/etc/doorview/mqtt.conf` exists |

## Where the numbers come from

Module parameters and timings (`tx_max_len=768`, `rx_burst=1`, `rx_gpio=36`, `irq_rx=1`, `rx_poll_ms=100`, MTU 700, 12 µs bit time, 12 MHz one-bit SDIO) are the values that were tested; see [wifi-companion.md](../docs/wifi-companion.md) for why.
