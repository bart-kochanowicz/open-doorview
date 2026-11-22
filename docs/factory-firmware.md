# How the factory firmware saves power and detects people

The factory firmware ran for weeks on one battery charge. OpenIPC with this repository's drivers ran for about 15 hours (2026-11-22, below). This page explains the difference from a reverse-engineering pass over the factory RTOS image (`p2pcam.bin`, loaded at `0x40000000`) and the coprocessor's own UART log. It also lists the coprocessor commands that would be needed to put the camera to sleep from Linux.

Evidence levels: **observed** (seen on the unit), **from the factory firmware** (read from the RTOS image or the factory UART logs, not exercised by us), **assumption** (inferred, not tested). Function names below are the factory firmware's own: they appear in its log strings and were used to name the functions in a Ghidra analysis. Addresses refer to the factory image as loaded. The image, the analysis database and the decompiled code are private and not in this repository.

## Summary

- **The SoC is switched off most of the time.** The Wi-Fi/battery coprocessor (a Hi3861L, SDK `Hi3861LV100R001C00SPC032`, coprocessor firmware `3.2.23`; from its UART log) stays on. It keeps the Wi-Fi association and can keep a TCP connection to a server. It powers the SoC on for a PIR alarm, a button, a wake-up packet from the server, USB power or a timer. After the event the SoC asks to be switched off again. OpenIPC instead keeps the SoC, the sensor, the ISP and the encoder running all the time, so trimming Linux alone cannot reach weeks.
- **The PIR sensor belongs to the coprocessor.** The SoC switches it on and sets its sensitivity with two commands. In the factory UART log (2026-11-17) the coprocessor reported `isEnablePir:0`: the PIR was off on this unit at that time.
- **Person detection ran on the camera.** HiSilicon's `hi_ivp` library is linked into the image, together with a model file (`/home/res_ivp/res_ivp_zip.bin`). After a PIR wake-up the firmware waits for its result, then either sends an alarm or goes back to sleep at once ("PIR NO HUMAN, SLEEP"). OpenIPC does not include this library.
- **Everything needed for the power cycle can be sent over the link we already drive.** The commands are frames on the same SDIO control channel that the stage 3 driver already uses for the station commands. None of them has been sent yet.

## Measured on 2026-11-22 (observed, Home Assistant history)

| Time | Battery | Note |
|---|---|---|
| 13:41 | 100 | USB unplugged |
| 15:40 | 85 | |
| 17:40 | 74 | |
| 19:29 | 64 | right after a restart |
| 21:28 | 51 | |
| 22:30 | 13 | one reading with the screen on after a button press; 51 again one minute later |
| 22:33 | | USB connected again |
| 23:27 | 88 | on USB, charging |

The camera ran on battery for 8 h 50 min and lost about half of the reported value, so a full charge lasts about 15 to 18 hours. The jumps to 13 (screen on) and 88 (charging) show that the value follows the battery voltage (see the battery scale below).

## The coprocessor link

The SoC and the coprocessor exchange **messages** inside the SDIO control frames described in [the Wi-Fi coprocessor](wifi-companion.md). Each message starts with an 8-byte header followed by the payload (from `PDT_SYSLINK_SendAsyncCmdMsg` at `0x40133c20`):

| Offset | Size | Meaning |
|---|---|---|
| 0 | 1 | channel: `0x8a` the coprocessor's application, `0x9a` its Wi-Fi part, `0x8b` its firmware upgrade |
| 1 | 1 | command |
| 2 | 1 | 1 for the first fragment |
| 3 | 1 | 1 for the last fragment |
| 4 | 2 | offset of this fragment (little endian) |
| 6 | 2 | 8 + payload length (little endian) |

Messages longer than 450 payload bytes are split into fragments. In the stage 3 driver this header is bytes 32 to 39 of the SDIO frame (`send_station_request` builds `9a <op> 01 01`). The driver also copies the length into byte 28. Byte 20 to 23 of the SDIO frame carry a queue identifier: `0x20a0b003` for `0x9a`, and `0x20a0b002` for `0x8a` (from the RAM test of 2026-11-18).

A synchronous request waits for a reply with the same channel and command + 1 (`PDT_SYSLINK_SendSyncCmdMsg`).

### Commands from the SoC (from the factory firmware)

`0x8a` (application):

| Cmd | Payload | Meaning | Where it is used |
|---|---|---|---|
| `0x51` | none | start a coprocessor firmware upgrade | `PDT_MCU_UPG_Update`; never send |
| `0x61` | 4 bytes, u32 | answer to `0xa0`: 1 = ready to be switched off, 0 = busy | `PDT_SYSLINK_DeinitCamera` |
| `0x63` | 3 bytes | coprocessor log level and dump switch | `HI_PDT_SYSTEM_SetLogLevel` |
| `0x64` | none | request the coprocessor version (answer `0xa1`) | test shell |
| `0x65` | 4 bytes | unknown setting, cached by the SoC | not traced |
| `0x71` | none | reboot the SoC | `HI_MCUCTRL_SOCReboot` |
| `0x72` | none | switch the SoC off | `HI_MCUCTRL_SOCPowerDown` |
| `0x73` | none | reset the coprocessor | `HI_MCUCTRL_MCUReset`, after a factory reset |
| `0x77` | 1 byte | SoC state: 1 during an upgrade, 2 otherwise, **7 just before standby** (assumption from the callers) | `HI_PDT_SYSTEM_Standby`, `HI_HAL_WIFI_STAStandby` |
| `0x78` | 2 bytes, u16 = PIR setting (0 = off; the other values are the cloud setting, probably 1 to 3) | switch the PIR | `hi_los_service_init`, `_setPirSwitch`, `PDT_TEST_MCU_ClosePIR` |
| `0x79` | 2 bytes, u16 = sensitivity << 8 | PIR sensitivity | `hi_los_service_init`, `_setPirSens` |
| `0x7a` | 6 bytes | set the coprocessor clock | `PDT_TEST_MCU_SetDateTime` |
| `0x7b` | 4 bytes, u32 seconds (0 = off) | wake-up timer | `HI_HAL_WIFI_STAStandby`, `PDT_TEST_MCU_SetWakeUpTimer` |
| `0x7c` | 16 bytes | unknown, no direct caller (probably the "default data" that the coprocessor logs as `longAlive`, `maxAliveTime` and the battery limits; assumption) | |
| `0x7e` | 1 byte | **coprocessor watchdog over the SoC** (`SET_HEARTBEAT` in the coprocessor log) | `0x4014a384` |
| `0x92` | none, sync, 4-byte answer | read the power state | `HI_MCUCTRL_GetCurPowerInfo` |

`0x9a` (Wi-Fi part):

| Cmd | Payload | Meaning |
|---|---|---|
| `0x01` | none | reset addresses |
| `0x03` | none | **system standby**: the SoC is about to be switched off |
| `0x04`, `0x05` | none | stop, start the server keep-alive |
| `0x06` | none | ultra-deep sleep (`HI_MCUCTRL_SystemClose`, everything off) |
| `0x07` | 304 bytes | keep-alive server authentication |
| `0x20`, `0x21` | 136 bytes, none | soft AP start, stop |
| `0x22`, `0x23`, `0x24`, `0x26` | | station start, stop, connect, disconnect (`0x22` to `0x24` are used by our driver) |
| `0x28` | none, sync, 4-byte answer | signal strength |
| `0x2a` | 1 byte | scan |
| `0x2c` | 261 bytes | wake-up packet pattern (`HAL_WIFI_SetNetPattern`) |
| `0x30` | 293 bytes | keep-alive server parameters (`HAL_WIFI_SetKeepAlive`) |

### Messages from the coprocessor (from the factory firmware, dispatch table at `0x40537ee4`)

| Cmd | Meaning | Note |
|---|---|---|
| `0x01` | factory reset requested | |
| `0x02` | low battery alarm | |
| `0x03` | **PIR alarm**; payload byte 0: 1 = start, 0 = end | `PDT_SYSLINK_PirAlarm` |
| `0x04` | Wi-Fi alarm | |
| `0x05`, `0x06` | external power in, out | |
| `0x07` | key event | |
| `0x08`, `0x09` | debug report, get info | |
| `0xa0` | **"deinit camera"**: the coprocessor asks whether it may switch the SoC off; the SoC answers `0x61` | `PDT_SYSLINK_DeinitCamera` |
| `0xa1` | coprocessor version | |
| `0xa2` | PowerInfo (status, usb, capacity) | observed, see [the Wi-Fi coprocessor](wifi-companion.md) |
| `0xa3` | coprocessor upgrade finished | |
| `0xa4` | ring key | |
| `0xa5` | "Wi-Fi key": **the front button on this unit** | observed: the button arrives as `0xa5` |
| `0xa6` | tamper key | |
| `0xb0` | standby notice (the factory handler only logs it) | |

The stage 3 driver logs every `0x8a` message as `doorview_control: command=..`, so a PIR alarm would appear as `command=03` without any driver change.

## Why the RAM test of 2026-11-18 silenced the camera

The test sent `8a:7e` with payload `01`. The factory firmware names this command `SET_HEARTBEAT`, and the coprocessor counts heartbeats from the SoC (`losHbCnt` in its log) and prints `mcu check los heatbeat`. **Assumption:** `01` switched on a watchdog that expects regular heartbeats from the SoC. The test module never sent them, so the coprocessor switched the SoC off, and only the power button brought it back. This fits what was observed: a silent UART and a camera that needed the button. In the factory boot log the coprocessor prints `HI_SYSLINK_MSG_S2M_SET_HEARTBEAT [0]!` right after the link comes up; whether `[0]` is the payload is not known. Do not send `0x7e` with a non-zero value.

## The wake-up reason

When the coprocessor powers the SoC on, the first exchange on the two wake-up GPIOs (what `syslink_poll.ko` does) carries the **reason** as a string. The factory boot log shows `send wakup reason:poweron, len:8 to camera`. The frame is a length byte, the string with its NUL, and a check byte (bitwise NOT of the XOR of the bytes before it). That is exactly the `08 "poweron\0" <check>` frame that our driver accepts. The factory firmware knows these strings (`HI_PDT_SYSLINK_GetWakeUpReason` at `0x401347ac`):

| String | Code | Meaning |
|---|---|---|
| `pir` | 0 | PIR alarm |
| `timer` | 1 | wake-up timer (`0x7b`) |
| `key` | 2 | key |
| `poweron` | 3 | power applied, or anything unknown |
| `wifi` | 4 | wake-up packet from the server (the pattern of `0x2c`) |
| `electry` | 5 | probably external power |
| `usb` | 6 | USB |
| `dropline` | 7 | Wi-Fi connection lost |
| `ringkey` | 8 | ring key |
| `wifikey` | 9 | Wi-Fi key (probably the front button, see `0xa5`) |
| `tamperkey` | 10 | tamper key |

**Gap in our driver:** `syslink_poll.c` accepts only `poweron`. Each of the other strings is shorter or longer than `poweron`, so the frame has another length and our driver would reject it. Then the link would not come up. Only `poweron` has ever been seen on the unit, because the SoC was never switched off.

## The factory power cycle (from the factory firmware)

1. **Wake-up.** The coprocessor powers the SoC and sends the reason. The factory U-Boot runs `quickstart` before the RTOS. Together with `HI_PDT_QUICKSTART_InitOsDrv` and the sensor's quick-start flag, this suggests that the sensor and the ISP are prepared before the application starts (assumption). In the factory boot log the SoC asked for the wake-up reason **0.44 s after the coprocessor switched it on** (`poweron soc finished` at 0.794 s, first `FillBootInfo` at 1.236 s of coprocessor time).
2. **Detection** (`los_wakeup_check_record` at `0x400dd818`). For a PIR wake-up the firmware caches a snapshot, starts `hi_ivp` and polls every 100 ms until the detector has finished:
   - **person:** "PIR HUMAN ONLINE RECORD" (cloud alarm and recording) or "OFFLINE RECORD" (SD card);
   - **no person:** "PIR NO HUMAN, SLEEP" and a standby request at once;
   - the `bird` variants mean an alarm without a person when that mode is configured.
3. **Staying awake.** An alive timer (`PDT_STATEMNG_CreateAliveTimer`; `maxAliveTime = 20` in the coprocessor log, default 180 s) and a 5 s check (`PDT_STATEMNG_WakeupCheckStandbyTimeOutTimerProc`) decide when to sleep. `hi_los_is_readby_standby` refuses while a live stream, an upgrade, a reset, a recording, the LCD, playback or a Wi-Fi connection is in progress. After about five minutes of refusals it gives in.
4. **Standby** (`HI_PDT_SYSTEM_Standby` at `0x4014f4fc`, `HI_HAL_WIFI_STAStandby` at `0x40149138`):
   1. optionally `9a:30` (keep-alive server) and `9a:2c` (wake-up pattern), then `9a:05` and the server authentication: this is what allows a wake-up from the cloud;
   2. `8a:7b` with the next timer wake-up, if any;
   3. **`8a:77 07`**;
   4. **`9a:03`**;
   5. the coprocessor asks with `0xa0`, and the SoC answers **`8a:61 01 00 00 00`** when it is ready (order inferred from the handlers);
   6. the SoC waits about 5 (assumed seconds) and reboots itself if it is still powered ("standby timeout, soc reboot now").

**The coprocessor's own guard (observed in its UART log under OpenIPC):** about 70 s after its start it printed `mcu check soc alive: 1, syslink established:0, system reboot` and restarted the system, because the SoC had not brought up the link in time. Our drivers bring the link up well before that; the coprocessor UART has not been watched since, so this is not confirmed.

## Battery scale (from the coprocessor log)

The coprocessor logs `capacity:<raw> min:458 lwo:475 percent:<n>` and, when the link comes up, `bCfg1 = 458`, `bCfg2 = 475`, `bCfg3 = 558`. The logged pairs fit `percent = (raw − 458) × 100 / (558 − 458)`, capped at 99 while charging (raw 521 → 63; raw 565 → 99). **Assumption:** the raw value follows the battery voltage (558 near full, 475 the low warning, 458 empty). This explains the 13 % reading under load and the 88 % reading on the charger.

## Where the cloud sits

The application calls the Tuya IPC SDK, which brings its own MQTT client, libuv, mbedTLS, P2P streaming and cloud storage. The calls from the product code are few and named: `tuya_ipc_init_sdk`, `tuya_ipc_start_sdk`, `tuyaHumanDetect`, `tuyaPirDetect`, `tuya_ipc_notify_with_event`, `tuya_ipc_notify_door_bell_press_generic`, and the standby gate `is_tuya_can_standby`. When the cloud does not answer, the firmware logs "SendOnlineNotice failed … standby now" and also has an offline path (`PIR … OFFLINE RECORD`). The power cycle itself (steps 1 to 4) has no cloud call apart from the optional keep-alive server.

## Two ways forward

**A. Linux with the factory power cycle (recommended).** We keep the drivers and add the missing parts:

1. `syslink_poll`: accept every reason string and record it, for example as a kernel log line that the daemon publishes.
2. The network driver: send `8a` messages as well as `9a` (same header, other queue identifier).
3. A standby request: `8a:77 07`, then `9a:03`, then the answer `8a:61 1` when `0xa0` arrives.
4. PIR on (`8a:78`, `8a:79`). It should also produce `0x03` alarms while the SoC is awake, which is cheaper and more reliable than video motion detection.
5. Person detection on the home server, from the snapshot that is already sent.

The open questions:

- How long Linux takes from power-on to the first picture (never measured). The factory firmware needs about half a second.
- The two early resets that every software reboot showed.
- Whether the coprocessor behaves the same with our timing.

A wake-up from Home Assistant would need our own keep-alive server instead of the cloud's: the formats of `0x2c` and `0x30` are not decoded yet.

**B. The factory image without the cloud.** We would keep the RTOS, the quick start and `hi_ivp`, and replace the Tuya calls with a small client for our broker. The power cycle and the detector would then be the original ones. The obstacles:

- The factory flash has never been restored, and that would include the factory U-Boot.
- On 2026-11-17 the factory firmware on this unit restarted every few seconds; the cause was never found (`findings.txt` of the first analysis, and the coprocessor log, which shows the SoC re-sending its settings every 11 s).
- The patch would be binary surgery on a 7 MB image without symbols.
- Every test would be a full flash write.

## Not established

- The meaning of the PIR setting values above 0, and the sensitivity range.
- The payloads of `0x65`, `0x7c`, `0x2c` and `0x30`.
- Whether the coprocessor switches the SoC off after `9a:03` without the server keep-alive, and how long it waits for the `0x61` answer.
- Whether the factory power-cycle order is the same on other coprocessor firmware versions (one unit, `3.2.23`).
