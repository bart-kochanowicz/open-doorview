/* The kernel log: power frames, buttons and PIR alarms from the syslink driver.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

static int hex_value(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return -1;
}

static int pir_alarm_pending;

/* "doorview_power: command=03 ... payload=01" is the start of a movement, 00 its end. */
static void handle_pir_line(const char *line, int length)
{
    const char *payload;

    if (replaying || !find_text(line, length, "doorview_power: command=03 "))
        return;
    activity_seen = 1;
    payload = find_text(line, length, "payload=");
    if (cfg.pir_motion && payload && payload + 10 <= line + length && payload[8] == '0' && payload[9] == '1')
        pir_alarm_pending = 1;
}

static void handle_power_line(const char *line, int length)
{
    const char *payload = find_text(line, length, "payload=");
    u8 bytes[4];
    int count = 0;
    int capacity;

    if (!payload || !find_text(line, length, "command=a2"))
        return;
    payload += 8;
    while (count < 4 && payload + 1 < line + length) {
        int high = hex_value(payload[0]);
        int low = hex_value(payload[1]);

        if (high < 0 || low < 0)
            break;
        bytes[count++] = (u8)(high * 16 + low);
        payload += 2;
        if (payload < line + length && *payload == ' ')
            payload++;
    }
    if (count < 4)
        return;
    capacity = (short)(bytes[2] | (bytes[3] << 8));
    if (bytes[0] != power_status) {
        power_status = bytes[0];
        dirty_status = 1;
    }
    if (bytes[1] <= 1 && bytes[1] != usb) {
        usb = bytes[1];
        dirty_usb = 1;
    }
    /* A negative capacity means "no fresh reading": keep the cached value. */
    if (capacity >= 0 && capacity <= 100 && capacity != battery) {
        battery = capacity;
        dirty_battery = 1;
    }
}

static void handle_button_line(const char *line, int length)
{
    u32 stamp = 0;
    int commas = 0;
    int index = 0;
    int digits = 0;

    if (!find_text(line, length, "doorview_control: command=a5 length=8"))
        return;
    if (replaying)
        return;
    while (index < length && commas < 2) {
        if (line[index] == ',')
            commas++;
        index++;
    }
    while (index < length && line[index] >= '0' && line[index] <= '9') {
        stamp = stamp * 10u + (u32)(line[index] - '0');
        index++;
        digits++;
    }
    /* One physical press produces a burst of records; count it once. */
    if (digits && have_last_button && (stamp - last_button_us) < BUTTON_DUPLICATE_US) {
        last_button_us = stamp;
        return;
    }
    if (digits) {
        last_button_us = stamp;
        have_last_button = 1;
    }
    pending_buttons++;
    activity_seen = 1;
}

static void handle_kmsg_text(const char *text, int length)
{
    int start = 0;
    int index;

    for (index = 0; index <= length; index++) {
        if (index == length || text[index] == '\n') {
            int line_length = index - start;

            if (line_length > 0) {
                handle_power_line(text + start, line_length);
                handle_pir_line(text + start, line_length);
                handle_button_line(text + start, line_length);
            }
            start = index + 1;
        }
    }
}

static void drain_kmsg(int fd)
{
    static char text[KMSG_MAX];
    int rounds;

    for (rounds = 0; rounds < 512; rounds++) {
        int count = sys_read(fd, text, sizeof(text));

        if (count == SYS_EAGAIN || count == 0) {
            replaying = 0;
            return;
        }
        if (count == SYS_EPIPE)
            continue; /* the record was overwritten; try the next one */
        if (count < 0)
            return;
        handle_kmsg_text(text, count);
    }
}
