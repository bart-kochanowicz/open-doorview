# The Wi-Fi, battery and button coprocessor ("syslink")

The RH-PD10 has no Wi-Fi in its SoC. Wi-Fi, battery/USB state and the front button all come from a separate microcontroller on the board, reached over **SDIO** plus a few GPIOs. The factory RTOS calls the protocol "syslink". OpenIPC has no driver for it, so this repository carries its own (`firmware/kernel/`). This page records what was learned and how sure we are of each point.

Evidence levels used below: **observed** (seen on the unit, logs or measurements), **from the factory firmware** (read from the RTOS binary, not exercised by us), **assumption** (inferred, not tested).

## The hardware path

| Item | Value | Evidence |
|---|---|---|
| Coprocessor | Hi3861-class MCU (working identification; the stock log names a "Hi3861" controller) | Stock UART log; the exact package was not checked |
| SDIO device | vendor `0x0296`, device `0x5347` on `mmc1`, function 1 | observed |
| SDIO mode | **1-bit bus, 12 MHz**. Four-bit and 25 MHz attempts produced timeouts or lost the console | observed |
| Wake-up lines | GPIO4_0 (SoC → MCU) and GPIO4_1 (MCU → SoC) on `120b4000.gpio_chip`, used as a bit-banged serial exchange at 12 µs per bit | observed |
| Data-ready interrupt | GPIO4_4 = Linux GPIO 36 = IRQ 79; the factory RTOS wakes its receive worker from it | from the factory firmware; interrupts observed on the unit |
| Power | the MCU is **not** reset by a software `reboot` | observed |

The factory firmware's configuration also lists an ADC channel for day/night detection. It is **not** the battery sensor (an early guess that proved wrong): battery state comes from the MCU, below.

## Bring-up sequence (what `S39doorview` and `syslink_poll.ko` do)

1. `syslink_poll.ko bit_us=12` takes over the two wake-up GPIOs, sends the three bytes `01 02 00`, and waits for the MCU's reply: a 10-byte frame `08 "poweron\0" <check>` (check = bitwise NOT of the XOR of the first nine bytes). If valid, it acknowledges with `02 03 01`, restores the SDIO pin mux and calls the kernel's `bsp_sdio_rescan(1)`, so the SDIO function appears as `/sys/bus/sdio/devices/mmc1:0001:1`.
2. If the device is missing, `S39doorview` unloads the module and tries again, up to ten times (about 10 s).
3. `syslink_bg.ko` (the *background* driver) completes the SDIO handshake: it writes `0x55` to function-0 register `0x24`, sets a 512-byte block size, and answers the MCU's connect frames for ports 0, 2 and 3. It then keeps the link alive with a **500 ms heartbeat** whose payload is `01 00 6c 73`. This is what the factory firmware does.
4. At `S41doorview-network` time `syslink_bg.ko` is replaced by a network driver (`syslink_net.ko`, polling, or `syslink_net_irq.ko`, interrupt-driven) that takes over the same SDIO function, keeps the heartbeat, and presents the radio as the `dv0` Ethernet interface.

## Network driver

- Ethernet frames travel over SDIO as packets with an SDIO header; the driver imposes **MTU 700** and a TX length cap of 768 bytes (module parameters `tx_max_len`). A larger MTU was not tested.
- Receive: the driver reads the length register at function offset `0x0c`, then the FIFO. The polling variant sleeps between reads. The interrupt variant (`irq_rx=1 rx_gpio=36`) reads when GPIO 36 signals, with a 100 ms fallback poll (`rx_poll_ms`). `rx_burst=1` allows up to eight consecutive reads before sleeping, which compensates the 10 ms scheduler tick of this kernel.
- The polling path (including the fallback poll of the interrupt-driven variant) delivers duplicate frames; a small filter (`rx_dedup`, FNV-1a over the frame, eight-entry ring, 2 s window) drops them. With it, ping latency fell from about 199 ms to 74 ms and RTSP decoded 100/100 frames.
- Station control commands are SDIO control frames with header `9a <op> 01 01`: `0x22` start station, `0x23` stop, `0x24` connect (64 bytes: SSID field then passphrase field, each 32 bytes NUL-padded, exactly what `station.hex` holds), `0x2a` scan (from the factory firmware). `0x28` (RSSI/AP query) exists in the factory firmware but **has never been sent**.
- Writing `station.hex` into `/sys/module/syslink_net/parameters/station` queues start+connect. `reconnect` queues stop+start+connect. Neither is documented by the vendor; they were derived from the factory RTOS and tested.

Behaviour you should know about:

- **Only 2.4 GHz WPA2-PSK was used.** Open networks, WPA3 and passphrases of 32 to 63 characters are not supported: the fields are 32 bytes and the drivers reject a field whose last byte is not NUL, so SSID and passphrase are limited to 31 bytes.
- **DHCP never produced a lease** in testing; a static IPv4 address is configured instead. Ask your router to reserve it.
- On the first drivers, ARP requests *from other hosts* did not always reach the camera (the gateway's did). The cause was not established; the interrupt-driven driver with the duplicate filter did not show it again, but cold-neighbour-cache behaviour from a second client was never systematically retested.

## Control frames from the MCU

Frames with header `0x0034`, `data[32] == 0x8a` carry application messages; `data[33]` is the command.

| Command | Meaning | Format | Evidence |
|---|---|---|---|
| `0xA2` PowerInfo | battery and USB state, sent periodically | `count=44`, `length=12`; four data bytes: **status**, **usb**, **capacity** (int16, little endian). Example: `02 01 63 00` = status 2, usb 1, capacity 99 | observed |
| `0xA5` button | front button | `length=8`; one press arrives as a **burst of 12 to 40 records** | observed |

How to read PowerInfo:

- `usb` is 1 with USB power and 0 without: confirmed by unplugging and replugging (the value changed within one burst each time).
- `status` was **1 on battery and 2 with USB**. Whether 2 means "charging" or "full" is not known.
- `capacity` showed 99 for every observation, which was taken as percent; **no other value was ever seen**, so the scale is an assumption. A negative value is a "no fresh reading" marker in the factory firmware (the cached value is kept).
- The factory firmware also has a battery query (`0x92`) that was not tried.

The driver prints these in the kernel log: `doorview_control: command=a5 length=8` for the button, and `doorview_power: command=a2 count=44 length=12 head=... payload=...` for power. The LCD service and the MQTT daemon read them from `/dev/kmsg`. **The exact text of the button line is parsed by the button listener**; do not change it.

## Why the interrupt-driven driver is the shipped one

With the polling driver the link repeatedly went silent: the frame counter froze, the "FIFO empty" counter grew by about 100 per second, and the MCU's button messages stopped, so the button did nothing. Silence began at about 40 s, 490 s and 1,870 s after boot in separate runs, with no button press involved. The interrupt-driven driver ran 45 and 47 minutes without a stall (`FIFO empty=0`, `errors=0` in every sample) and four of four button tests worked. About 100 minutes of total observation is **all the evidence there is**: earlier stalls came at random times up to 31 minutes, so a rare failure cannot be excluded.

## Things that went wrong, so you can avoid them

- **`8A:7E` with payload `01`** (the factory firmware's "enable MCU heartbeat" application command) was sent once from a test module. The UART went silent and the camera needed a press of its power button. It is not part of any shipped file. Do not send commands to the MCU that the shipped drivers do not send.
- A **full SDIO reset** silenced the UART. A function disable/enable returned success with the FIFO still empty.
- **Repeated station stop/start/connect sequences**, and `reconnect` on a dead data path, did not recover traffic and in one case ended with the Wi-Fi unusable until the camera lost **all power**. A soft `reboot` does not reset the MCU.
- A 25 MHz clock gave a faster stream followed by an SDIO timeout and a reboot. Four-bit mode failed during initialisation.
- The Linux console sometimes restarted early in boot (before `S41`) with no recorded cause, on both the polling and the interrupt-driven setups. A watchdog is initialised by the kernel; whether it is the cause is not established.

## Source map

| File | Purpose |
|---|---|
| `firmware/kernel/syslink-handshake/syslink_poll.c` | GPIO wake-up exchange and SDIO rescan |
| `firmware/kernel/syslink-handshake/syslink_bg.c` | SDIO handshake and heartbeat (the shipped binary is an earlier revision; see [known limits](known-limits.md)) |
| `firmware/kernel/syslink-net-poll/syslink_net.c` | stage 1 network driver (polling) |
| `firmware/kernel/syslink-net-irq-stage2/syslink_net.c` | stage 2 network driver (interrupt-driven) |
| `firmware/kernel/syslink-net-irq/syslink_net.c` | stage 3 network driver: stage 2 plus the `doorview_power` log line |
