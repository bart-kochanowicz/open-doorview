/* The configuration file (mqtt.conf) and its checks.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

static int valid_identifier(const char *text, int allow_space)
{
    int index;

    if (!text[0])
        return 0;
    for (index = 0; text[index]; index++) {
        char c = text[index];

        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_')
            continue;
        if (allow_space && ((c >= 'A' && c <= 'Z') || c == ' ' || c == '.'))
            continue;
        return 0;
    }
    return 1;
}

/* A request path that cannot smuggle a second header line into the GET: no spaces or control characters. */
static int valid_path(const char *text)
{
    int index;

    if (text[0] != '/')
        return 0;
    for (index = 0; text[index]; index++) {
        char c = text[index];

        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '.' ||
            c == '_' || c == '-' || c == '?' || c == '&' || c == '=' || c == '%')
            continue;
        return 0;
    }
    return 1;
}

static int parse_address(const char *text, u32 *address)
{
    u32 result = 0;
    int parts = 0;

    while (parts < 4) {
        u32 value = 0;
        int digits = 0;

        while (*text >= '0' && *text <= '9') {
            value = value * 10u + (u32)(*text - '0');
            if (++digits > 3 || value > 255u)
                return 0;
            text++;
        }
        if (!digits)
            return 0;
        result = (result << 8) | value;
        parts++;
        if (parts < 4) {
            if (*text != '.')
                return 0;
            text++;
        }
    }
    if (*text)
        return 0;
    *address = result;
    return 1;
}

static int parse_number(const char *text, int *value)
{
    int result = 0;
    int digits = 0;

    while (*text >= '0' && *text <= '9') {
        result = result * 10 + (*text - '0');
        if (++digits > 6)
            return 0;
        text++;
    }
    if (!digits || *text)
        return 0;
    *value = result;
    return 1;
}

static int load_config(const char *path)
{
    char buffer[CONFIG_MAX];
    int length = 0;
    int fd = sys_open_read(path, 0);
    int position = 0;
    int have_host = 0;

    if (fd < 0)
        return -1;
    for (;;) {
        int count = sys_read(fd, buffer + length, CONFIG_MAX - 1 - length);

        if (count <= 0)
            break;
        length += count;
        if (length >= CONFIG_MAX - 1)
            break;
    }
    sys_close(fd);
    buffer[length] = 0;

    cfg.port = 1883;
    cfg.keepalive = 60;
    cfg.motion_port = 80;
    cfg.motion_video = 1;
    cfg.motion_hold = 10;
    cfg.motion_window = 3;
    cfg.live_seconds = 30;
    cfg.live_interval_ms = 500;
    str_copy(cfg.live_path, sizeof(cfg.live_path), "/image.jpg?width=640&height=360&qfactor=40");
    cfg.snapshot_cooldown = 30;
    str_copy(cfg.snapshot_path, sizeof(cfg.snapshot_path), "/image.jpg?qfactor=60");
    str_copy(cfg.reason_file, sizeof(cfg.reason_file), "/sys/module/syslink_poll/parameters/reason");
    str_copy(cfg.mcu_parameter, sizeof(cfg.mcu_parameter), "/sys/module/syslink_net/parameters/mcu");
    str_copy(cfg.standby_parameter, sizeof(cfg.standby_parameter), "/sys/module/syslink_net/parameters/standby");
    str_copy(cfg.stay_awake_file, sizeof(cfg.stay_awake_file), "/tmp/doorview-stay-awake");
    str_copy(cfg.node, sizeof(cfg.node), "front-door-camera");
    str_copy(cfg.name, sizeof(cfg.name), "Front door camera");
    str_copy(cfg.discovery, sizeof(cfg.discovery), "homeassistant");
    str_copy(cfg.kmsg, sizeof(cfg.kmsg), "/dev/kmsg");
    str_copy(cfg.uptime, sizeof(cfg.uptime), "/proc/uptime");
    str_copy(cfg.rx_stats, sizeof(cfg.rx_stats), "/sys/class/net/dv0/statistics/rx_packets");
    str_copy(cfg.station_file, sizeof(cfg.station_file), "/etc/doorview/station.hex");
    str_copy(cfg.reconnect_parameter, sizeof(cfg.reconnect_parameter), "/sys/module/syslink_net/parameters/reconnect");

    while (position < length) {
        char *line = buffer + position;
        char *equals = 0;
        char *value;
        int end = position;
        int number;

        while (end < length && buffer[end] != '\n')
            end++;
        buffer[end] = 0;
        position = end + 1;
        if (end > 0 && buffer[end - 1] == '\r')
            buffer[end - 1] = 0;
        if (line[0] == '#' || !line[0])
            continue;
        for (value = line; *value; value++) {
            if (*value == '=') {
                equals = value;
                break;
            }
        }
        if (!equals)
            continue;
        *equals = 0;
        value = equals + 1;
        if (str_eq(line, "host")) {
            if (!parse_address(value, &cfg.address))
                return -2;
            have_host = 1;
        } else if (str_eq(line, "port")) {
            if (!parse_number(value, &number) || number < 1 || number > 65535)
                return -3;
            cfg.port = (u16)number;
        } else if (str_eq(line, "keepalive")) {
            if (!parse_number(value, &number) || number < 2 || number > 600)
                return -4;
            cfg.keepalive = number;
        } else if (str_eq(line, "user")) {
            if (!store(cfg.user, sizeof(cfg.user), value))
                return -9;
        } else if (str_eq(line, "password")) {
            if (!store(cfg.password, sizeof(cfg.password), value))
                return -9;
        } else if (str_eq(line, "node")) {
            if (!valid_identifier(value, 0))
                return -5;
            if (!store(cfg.node, sizeof(cfg.node), value))
                return -9;
        } else if (str_eq(line, "name")) {
            if (!valid_identifier(value, 1))
                return -6;
            if (!store(cfg.name, sizeof(cfg.name), value))
                return -9;
        } else if (str_eq(line, "discovery")) {
            if (!valid_identifier(value, 0))
                return -7;
            if (!store(cfg.discovery, sizeof(cfg.discovery), value))
                return -9;
        } else if (str_eq(line, "kmsg")) {
            if (!store(cfg.kmsg, sizeof(cfg.kmsg), value))
                return -9;
        } else if (str_eq(line, "uptime_file")) {
            if (!store(cfg.uptime, sizeof(cfg.uptime), value))
                return -9;
        } else if (str_eq(line, "rx_stats")) {
            if (!store(cfg.rx_stats, sizeof(cfg.rx_stats), value))
                return -9;
        } else if (str_eq(line, "station_file")) {
            if (!store(cfg.station_file, sizeof(cfg.station_file), value))
                return -9;
        } else if (str_eq(line, "reconnect_parameter")) {
            if (!store(cfg.reconnect_parameter, sizeof(cfg.reconnect_parameter), value))
                return -9;
        } else if (str_eq(line, "wifi_watchdog")) {
            cfg.wifi_watchdog = str_eq(value, "1");
        } else if (str_eq(line, "wifi_reboot")) {
            if (!parse_number(value, &number) || number < 0 || number > 3600)
                return -21;
            cfg.wifi_reboot = number;
        } else if (str_eq(line, "motion")) {
            cfg.motion = str_eq(value, "1");
        } else if (str_eq(line, "motion_port")) {
            if (!parse_number(value, &number) || number < 1 || number > 65535)
                return -10;
            cfg.motion_port = number;
        } else if (str_eq(line, "motion_hold")) {
            if (!parse_number(value, &number) || number < 1 || number > 600)
                return -11;
            cfg.motion_hold = number;
        } else if (str_eq(line, "motion_min_rate")) {
            if (!parse_number(value, &number) || number < 0 || number > 10000)
                return -15;
            cfg.motion_min_rate = number;
        } else if (str_eq(line, "motion_window")) {
            if (!parse_number(value, &number) || number < 1 || number > 10)
                return -16;
            cfg.motion_window = number;
        } else if (str_eq(line, "motion_settle")) {
            if (!parse_number(value, &number) || number < 0 || number > 600)
                return -22;
            cfg.motion_settle = number;
        } else if (str_eq(line, "snapshot_delay_ms")) {
            if (!parse_number(value, &number) || number < 0 || number > 5000)
                return -17;
            cfg.snapshot_delay_ms = number;
        } else if (str_eq(line, "live")) {
            cfg.live = str_eq(value, "1");
        } else if (str_eq(line, "live_seconds")) {
            if (!parse_number(value, &number) || number < 1 || number > 300)
                return -18;
            cfg.live_seconds = number;
        } else if (str_eq(line, "live_interval_ms")) {
            if (!parse_number(value, &number) || number < 100 || number > 5000)
                return -19;
            cfg.live_interval_ms = number;
        } else if (str_eq(line, "live_path")) {
            if (!valid_path(value))
                return -20;
            if (!store(cfg.live_path, sizeof(cfg.live_path), value))
                return -9;
        } else if (str_eq(line, "snapshot")) {
            cfg.snapshot = str_eq(value, "1");
        } else if (str_eq(line, "snapshot_path")) {
            if (!valid_path(value))
                return -12;
            if (!store(cfg.snapshot_path, sizeof(cfg.snapshot_path), value))
                return -9;
        } else if (str_eq(line, "sleep_after")) {
            if (!parse_number(value, &number) || (number != 0 && (number < 10 || number > 3600)))
                return -23;
            cfg.sleep_after = number;
        } else if (str_eq(line, "motion_video")) {
            cfg.motion_video = str_eq(value, "1");
        } else if (str_eq(line, "pir_motion")) {
            cfg.pir_motion = str_eq(value, "1");
        } else if (str_eq(line, "pir_sensitivity")) {
            if (!parse_number(value, &number) || number < 0 || number > 5)
                return -27;
            cfg.pir_sensitivity = number;
        } else if (str_eq(line, "wake_timer")) {
            if (!parse_number(value, &number) || number < 0 || number > 604800)
                return -26;
            cfg.wake_timer = number;
        } else if (str_eq(line, "sleep_usb")) {
            cfg.sleep_usb = str_eq(value, "1");
        } else if (str_eq(line, "reason_file") || str_eq(line, "mcu_parameter") || str_eq(line, "standby_parameter") ||
                   str_eq(line, "stay_awake_file")) {
            char *target = str_eq(line, "reason_file")         ? cfg.reason_file
                           : str_eq(line, "mcu_parameter")     ? cfg.mcu_parameter
                           : str_eq(line, "standby_parameter") ? cfg.standby_parameter
                                                               : cfg.stay_awake_file;

            if (!valid_path(value))
                return -24;
            if (!store(target, 128, value))
                return -9;
        } else if (str_eq(line, "snapshot_cooldown")) {
            if (!parse_number(value, &number) || number < 1 || number > 3600)
                return -13;
            cfg.snapshot_cooldown = number;
        } else if (str_eq(line, "night_wait_ms")) {
            if (!parse_number(value, &number) || number < 0 || number > 8000)
                return -29;
            cfg.night_wait_ms = number;
        }
    }
    if (cfg.snapshot && !cfg.motion)
        return -14; /* the snapshot is taken when motion starts */
    if (cfg.pir_motion && !cfg.motion)
        return -28; /* a PIR alarm is reported as the motion entity */
    if (cfg.sleep_after && !cfg.snapshot)
        return -25; /* a wake-up is reported as motion with a snapshot */
    return have_host ? 0 : -8;
}
