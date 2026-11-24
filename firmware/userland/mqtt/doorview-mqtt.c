/* doorview-mqtt: publishes RH-PD10 battery, USB power, button presses and uptime to MQTT
 * (Home Assistant discovery). It follows the kernel log written by the syslink driver:
 *   doorview_power: command=a2 ... payload=SS UU CC CC   MCU PowerInfo: status, usb, capacity
 *   doorview_control: command=a5 length=8                button
 * With motion=1 it also polls Majestic's motion counter on the loopback interface (see fetch_motion_total), and with
 * snapshot=1 it publishes a JPEG from Majestic when motion starts, so Home Assistant never has to reach the camera.
 * With live=1 it subscribes to doorview/<node>/live/set and, on ON, publishes small pictures to doorview/<node>/live for
 * live_seconds (a slide show on demand); OFF or the time running out ends it.
 * With pir_motion=1 the PIR (switched on by the daemon; pir_sensitivity=1..5, the factory app uses 1, 3 and 5) is the motion source while the camera is awake
 * too: an alarm start in the kernel log is a motion edge with a snapshot, and motion_video=0 stops polling Majestic's video
 * motion detector.
 * With sleep_after=<seconds> it puts the camera to sleep, like the factory firmware, when nothing has happened for that
 * long: it switches the PIR on, syncs and asks the syslink driver for the standby (see docs/factory-firmware.md); a PIR
 * wake-up (reason "pir" in the syslink_poll parameter) is reported as motion with a snapshot, so Home Assistant sees it.
 * With night_wait_ms=<ms> the snapshot waits, at most that long, while Majestic's /metrics/night says the light has not
 * been measured yet or a switch to night is under way: a wake-up starts in day mode, and the first picture in the dark
 * would come before the IR LEDs.
 * With wake_server=<address>:<port> and wake_pattern=<12 hex digits> it arms the coprocessor's keep-alive before every
 * standby: while the camera sleeps the coprocessor keeps a connection to that server and wakes the SoC when the server
 * sends the pattern (reason "wifi", docs/remote-wake.md); after such a wake-up the live view starts by itself (live=1).
 * Platform access goes through sys.h, so the same logic runs on the camera and on a test host. The code is split by
 * topic into the files in parts/, included below in order. */
#include "sys.h"

#define CONFIG_MAX 1024
#define WAKE_PATTERN_SIZE 6
#define PACKET_MAX 1024
#define RECEIVE_MAX 512
#define KMSG_MAX 2048

#define CONNECT_TIMEOUT_MS 10000
#define BACKOFF_MIN_MS 2000
#define BACKOFF_MAX_MS 60000
#define UPTIME_PERIOD_MS 60000
#define BUTTON_DUPLICATE_US 250000u
#define MOTION_POLL_MS 1000u
#define MOTION_IO_MS 300u
#define METRICS_MAX 4096
#define SNAPSHOT_MAX 327680 /* largest JPEG published; a 1920x1080 picture is about 120 to 250 KB */
#define SNAPSHOT_RESPONSE_MAX (SNAPSHOT_MAX + 1024) /* HTTP headers included */
#define SNAPSHOT_HEAD 256 /* room in front of the response for the MQTT header */
#define SNAPSHOT_IO_MS 5000u
#define SNAPSHOT_PENDING_MS 10000u
#define SNAPSHOT_RETRY_MS 200u /* while Majestic is still starting */

struct config {
    u32 address;
    u16 port;
    int keepalive;
    char user[64];
    char password[64];
    char node[32];
    char name[48];
    char discovery[32];
    char kmsg[128];
    char uptime[128];
    char rx_stats[128];
    char station_file[128];
    char reconnect_parameter[128];
    int wifi_watchdog;
    int wifi_reboot;
    int motion;
    int motion_port;
    int motion_hold;
    int motion_min_rate;
    int motion_window;
    int motion_settle;
    int snapshot;
    int snapshot_cooldown;
    int night_wait_ms;
    int snapshot_delay_ms;
    int live;
    int live_seconds;
    int live_interval_ms;
    char live_path[128];
    char snapshot_path[128];
    int sleep_after;
    int sleep_usb;
    int wake_timer;
    int motion_video;
    int pir_motion;
    int pir_sensitivity;
    u32 wake_address;
    int wake_port;
    u8 wake_pattern[WAKE_PATTERN_SIZE];
    int wake_pattern_set;
    int wake_interval;
    char wifi_parameter[128];
    char reason_file[128];
    char mcu_parameter[128];
    char standby_parameter[128];
    char stay_awake_file[128];
};

static struct config cfg;

/* The parts, in this order: each one uses what the ones before it define. */
#include "parts/strings.c"
#include "parts/config.c"
#include "parts/mqtt.c"
#include "parts/state.c"
#include "parts/motion.c"
#include "parts/snapshot.c"
#include "parts/live.c"
#include "parts/kmsg.c"
#include "parts/watchdog.c"
#include "parts/connection.c"
#include "parts/sleep.c"

int app_main(const char *config_path)
{
    int kmsg_fd;
    int result = load_config(config_path);
    struct out prefix = { node_prefix, 0, (int)sizeof(node_prefix) - 1, 0 };

    if (result < 0) {
        logmsg("cannot read configuration");
        return 2;
    }
    put_text(&prefix, "doorview/");
    put_text(&prefix, cfg.node);
    node_prefix[prefix.length] = 0;
    topic(live_set_topic, sizeof(live_set_topic), "live/set");
    kmsg_fd = sys_open_read(cfg.kmsg, 1);
    if (kmsg_fd < 0) {
        logmsg("cannot open the kernel log");
        return 3;
    }
    {
        u32 now = sys_now_ms();

        last_up_ms = now;
        last_rx_change_ms = now;
        last_uptime_ms = now;
        last_motion_poll_ms = now;
        motion_settle_until_ms = now + (u32)cfg.motion_settle * 1000u;
        daemon_started_ms = now;
        next_attempt_ms = now;
        last_activity_ms = now;
    }
    read_wake_reason();
    logmsg("started");

    for (;;) {
        u32 now = sys_now_ms();
        int wait_ms = 1000;

        drain_kmsg(kmsg_fd);
        now = sys_now_ms();
        poll_motion(now);
        now = sys_now_ms();
        switch (link) {
        case LINK_DOWN:
            if ((int)(now - next_attempt_ms) >= 0)
                begin_connect(now);
            break;
        case LINK_CONNECTING: {
            int status = sys_tcp_status(socket_fd);

            if (status == 0) {
                int length = build_connect();

                if (length < 0 || send_all(packet, length)) {
                    link_fail("cannot send CONNECT");
                } else {
                    link = LINK_AWAIT_CONNACK;
                    deadline_ms = now + CONNECT_TIMEOUT_MS;
                }
            } else if (status < 0 || (int)(now - deadline_ms) >= 0) {
                link_fail("broker unreachable");
            }
            break;
        }
        case LINK_AWAIT_CONNACK:
            read_socket(now);
            if (link == LINK_AWAIT_CONNACK && (int)(now - deadline_ms) >= 0)
                link_fail("no CONNACK");
            break;
        case LINK_UP:
            read_socket(now);
            if (link != LINK_UP)
                break;
            last_up_ms = now;
            if (publish_states(0) || send_events()) {
                link_fail("publish failed");
                break;
            }
            if (wake_pir_pending || pir_alarm_pending)
                report_pir_motion(now);
            if (wake_live_pending) {
                wake_live_pending = 0;
                live_start(now);
            }
            /* After the wake-up picture: the PIR is already on after a PIR wake-up, the picture comes first. */
            if (cfg.pir_motion && !pir_setup_done && !snapshot_pending && !wake_pir_pending)
                pir_setup();
            if (snapshot_pending && (int)(now - snapshot_due_ms) >= 0) {
                int expired = (int)(now - snapshot_deadline_ms) >= 0;
                int cooling = have_snapshot && now - last_snapshot_ms < (u32)cfg.snapshot_cooldown * 1000u;

                snapshot_pending = 0;
                if (expired || cooling) {
                    night_waiting = 0;
                } else if (!night_ready(now)) {
                    snapshot_pending = 1;
                    snapshot_due_ms = sys_now_ms() + SNAPSHOT_RETRY_MS;
                } else {
                    int result = take_snapshot();

                    if (result != 1)
                        night_waiting = 0;
                    if (result < 0) {
                        link_fail("publish failed");
                        break;
                    }
                    if (result == 1) {
                        snapshot_pending = 1;
                        snapshot_due_ms = sys_now_ms() + SNAPSHOT_RETRY_MS;
                    } else {
                        last_snapshot_ms = now;
                        have_snapshot = 1;
                    }
                }
            }
            if (live_active) {
                if ((int)(now - live_deadline_ms) >= 0) {
                    live_stop();
                } else if ((int)(now - live_next_ms) >= 0) {
                    live_next_ms = now + (u32)cfg.live_interval_ms;
                    if (take_live_frame()) {
                        link_fail("publish failed");
                        break;
                    }
                    now = sys_now_ms();
                    if ((int)(live_next_ms - now) < 0)
                        live_next_ms = now; /* the picture took longer than the interval: no burst to catch up */
                }
            }
            if (dirty_live && publish_states(0)) {
                link_fail("publish failed");
                break;
            }
            if (now - last_uptime_ms >= UPTIME_PERIOD_MS) {
                last_uptime_ms = now;
                if (publish_uptime()) {
                    link_fail("publish failed");
                    break;
                }
            }
            /* The broker acknowledges nothing we publish, so a busy publisher must also ping when it has
             * heard nothing for half the keepalive; otherwise it would declare the broker dead below. */
            if (now - last_sent_ms >= (u32)cfg.keepalive * 500u ||
                (now - last_received_ms >= (u32)cfg.keepalive * 500u &&
                 now - last_ping_ms >= (u32)cfg.keepalive * 500u)) {
                static const u8 ping[2] = { 0xc0, 0 };

                last_ping_ms = now;
                if (send_all(ping, 2)) {
                    link_fail("keepalive failed");
                    break;
                }
            }
            if (now - last_received_ms > (u32)cfg.keepalive * 1500u) {
                link_fail("broker stopped answering");
                break;
            }
            maybe_sleep(now);
            break;
        }
        watchdog(now);
        if (snapshot_pending) {
            int until = (int)(snapshot_due_ms - now);

            wait_ms = until < 1 ? 1 : (until < wait_ms ? until : wait_ms);
        }
        if (live_active) {
            int until = (int)(live_next_ms - now);

            wait_ms = until < 1 ? 1 : (until < wait_ms ? until : wait_ms);
        }
        if (link == LINK_DOWN) {
            int until = (int)(next_attempt_ms - now);

            wait_ms = until < 0 ? 0 : (until < 1000 ? until : 1000);
        }
        sys_wait(kmsg_fd, socket_fd, link == LINK_CONNECTING, wait_ms > 0 ? wait_ms : 1);
    }
}
