/* The Wi-Fi watchdog and wifi_reboot.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

static u32 last_rx_value = 0xffffffffu;
static u32 last_rx_change_ms;
static u32 last_rx_sample_ms;
static u32 last_reconnect_ms;
static u32 daemon_started_ms;
static int reconnect_done;

static void request_wifi_reconnect(void)
{
    char station[160];
    int source = sys_open_read(cfg.station_file, 0);
    int target;
    int length;

    if (source < 0)
        return;
    length = sys_read(source, station, sizeof(station));
    sys_close(source);
    if (length <= 0)
        return;
    target = sys_open_write(cfg.reconnect_parameter);
    if (target < 0)
        return;
    sys_write(target, station, length); /* credentials stay inside the kernel; nothing is logged */
    sys_close(target);
    logmsg("wifi reconnect requested");
}

static void watchdog(u32 now)
{
    char text[24];
    int fd;
    int count;
    int index;
    u32 value = 0;

    if ((!cfg.wifi_watchdog && !cfg.wifi_reboot) || now - last_rx_sample_ms < 5000u)
        return;
    last_rx_sample_ms = now;
    fd = sys_open_read(cfg.rx_stats, 0);
    if (fd < 0)
        return;
    count = sys_read(fd, text, sizeof(text) - 1);
    sys_close(fd);
    for (index = 0; index < count && text[index] >= '0' && text[index] <= '9'; index++)
        value = value * 10u + (u32)(text[index] - '0');
    if (!index)
        return;
    if (value != last_rx_value) {
        last_rx_value = value;
        last_rx_change_ms = now;
    }
    /* A dead data path (observed: the received-packet counter stops while the broker is unreachable; the camera
     * recovered every time by restarting) is restarted after wifi_reboot seconds, but never in the first four times that
     * long after the start, so a path that is dead from boot on cannot make a tight restart loop. */
    if (cfg.wifi_reboot && link != LINK_UP && now - last_up_ms > (u32)cfg.wifi_reboot * 1000u &&
        now - last_rx_change_ms > (u32)cfg.wifi_reboot * 1000u &&
        now - daemon_started_ms > (u32)cfg.wifi_reboot * 4000u) {
        logmsg("wifi data path is dead, restarting the camera");
        sys_reboot();
    }
    /* Act only when the broker has been unreachable for a while AND no frame arrived at all. */
    if (cfg.wifi_watchdog && link != LINK_UP && now - last_up_ms > 180000u && now - last_rx_change_ms > 90000u &&
        (!reconnect_done || now - last_reconnect_ms > 300000u)) {
        request_wifi_reconnect();
        reconnect_done = 1;
        last_reconnect_ms = now;
    }
}
