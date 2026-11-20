/* doorview-mqtt: publishes RH-PD10 battery, USB power, button presses and uptime to MQTT
 * (Home Assistant discovery). It follows the kernel log written by the syslink driver:
 *   doorview_power: command=a2 ... payload=SS UU CC CC   MCU PowerInfo: status, usb, capacity
 *   doorview_control: command=a5 length=8                button
 * Platform access goes through sys.h, so the same logic runs on the camera and on a test host. */
#include "sys.h"

#define CONFIG_MAX 1024
#define PACKET_MAX 1024
#define RECEIVE_MAX 512
#define KMSG_MAX 2048

#define CONNECT_TIMEOUT_MS 10000
#define BACKOFF_MIN_MS 2000
#define BACKOFF_MAX_MS 60000
#define UPTIME_PERIOD_MS 60000
#define BUTTON_DUPLICATE_US 250000u

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
};

static struct config cfg;

/* ---- small string helpers (no libc) ---- */

static int str_len(const char *text)
{
    int length = 0;

    while (text[length])
        length++;
    return length;
}

static int str_eq(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return *a == *b;
}

static void str_copy(char *to, int capacity, const char *from)
{
    int index = 0;

    while (from[index] && index < capacity - 1) {
        to[index] = from[index];
        index++;
    }
    to[index] = 0;
}

/* Copies a configuration value only if it fits completely; a silently truncated path or password is worse than an error. */
static int store(char *to, int capacity, const char *from)
{
    if (str_len(from) >= capacity)
        return 0;
    str_copy(to, capacity, from);
    return 1;
}

static const char *find_text(const char *text, int length, const char *needle)
{
    int needle_length = str_len(needle);
    int index;

    for (index = 0; index + needle_length <= length; index++) {
        int match = 1;
        int offset;

        for (offset = 0; offset < needle_length; offset++) {
            if (text[index + offset] != needle[offset]) {
                match = 0;
                break;
            }
        }
        if (match)
            return text + index;
    }
    return 0;
}

/* Bounded output buffer. */
struct out {
    char *data;
    int length;
    int capacity;
    int overflow;
};

static void put_char(struct out *o, char value)
{
    if (o->length + 1 > o->capacity) {
        o->overflow = 1;
        return;
    }
    o->data[o->length++] = value;
}

static void put_text(struct out *o, const char *text)
{
    while (*text)
        put_char(o, *text++);
}

static void put_decimal(struct out *o, int value)
{
    /* No division: the freestanding ARM build has no runtime divide helper. */
    static const unsigned int powers[] = { 1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
                                           10000u,      1000u,      100u,      10u,      1u };
    unsigned int magnitude = value < 0 ? 0u - (unsigned int)value : (unsigned int)value;
    int started = 0;
    int index;

    if (value < 0)
        put_char(o, '-');
    for (index = 0; index < 10; index++) {
        unsigned int digit = 0;

        while (magnitude >= powers[index]) {
            magnitude -= powers[index];
            digit++;
        }
        if (digit || started || index == 9) {
            put_char(o, (char)('0' + digit));
            started = 1;
        }
    }
}

static void logmsg(const char *text)
{
    char line[96];
    struct out o = { line, 0, (int)sizeof(line) - 1, 0 };

    put_text(&o, "doorview-mqtt: ");
    put_text(&o, text);
    put_char(&o, '\n');
    sys_write(1, line, o.length);
}

/* ---- configuration ---- */

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
    str_copy(cfg.node, sizeof(cfg.node), "front-door-camera");
    str_copy(cfg.name, sizeof(cfg.name), "Front door camera");
    str_copy(cfg.discovery, sizeof(cfg.discovery), "homeassistant");
    str_copy(cfg.kmsg, sizeof(cfg.kmsg), "/dev/kmsg");
    str_copy(cfg.uptime, sizeof(cfg.uptime), "/proc/uptime");
    str_copy(cfg.rx_stats, sizeof(cfg.rx_stats), "/sys/class/net/dv0/statistics/rx_packets");
    str_copy(cfg.station_file, sizeof(cfg.station_file), "/etc/doorview/station.hex");
    str_copy(cfg.reconnect_parameter, sizeof(cfg.reconnect_parameter),
             "/sys/module/syslink_net/parameters/reconnect");

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
        }
    }
    return have_host ? 0 : -8;
}

/* ---- MQTT 3.1.1 packets ---- */

static u8 packet[PACKET_MAX];

static void put_byte(struct out *o, int value)
{
    put_char(o, (char)value);
}

static void put_string16(struct out *o, const char *text)
{
    int length = str_len(text);

    put_byte(o, length >> 8);
    put_byte(o, length & 0xff);
    put_text(o, text);
}

/* Writes the remaining-length prefix in front of a body already built at packet + 5. */
static int finish_packet(int first_byte, int body_length)
{
    int header_length = body_length < 128 ? 2 : 3;
    int start = 5 - header_length;
    int index;

    packet[start] = (u8)first_byte;
    if (body_length < 128) {
        packet[start + 1] = (u8)body_length;
    } else {
        packet[start + 1] = (u8)((body_length & 0x7f) | 0x80);
        packet[start + 2] = (u8)(body_length >> 7);
    }
    for (index = 0; index < header_length + body_length; index++)
        packet[index] = packet[start + index];
    return header_length + body_length;
}

static char node_prefix[64]; /* doorview/<node> */

static void topic(char *to, int capacity, const char *leaf)
{
    struct out o = { to, 0, capacity - 1, 0 };

    put_text(&o, node_prefix);
    put_char(&o, '/');
    put_text(&o, leaf);
    to[o.length] = 0;
}

static int build_connect(void)
{
    struct out o = { (char *)packet + 5, 0, PACKET_MAX - 5, 0 };
    char will_topic[96];
    int flags = 0x02 | 0x04 | 0x20; /* clean session, will, will retain */

    topic(will_topic, sizeof(will_topic), "availability");
    if (cfg.user[0])
        flags |= 0x80;
    if (cfg.user[0] && cfg.password[0])
        flags |= 0x40;
    put_string16(&o, "MQTT");
    put_byte(&o, 4);
    put_byte(&o, flags);
    put_byte(&o, cfg.keepalive >> 8);
    put_byte(&o, cfg.keepalive & 0xff);
    put_string16(&o, cfg.node);
    put_string16(&o, will_topic);
    put_string16(&o, "offline");
    if (cfg.user[0])
        put_string16(&o, cfg.user);
    if (cfg.user[0] && cfg.password[0])
        put_string16(&o, cfg.password);
    if (o.overflow)
        return -1;
    return finish_packet(0x10, o.length);
}

static int build_publish(const char *topic_name, const char *payload, int payload_length, int retain)
{
    struct out o = { (char *)packet + 5, 0, PACKET_MAX - 5, 0 };
    int index;

    put_string16(&o, topic_name);
    for (index = 0; index < payload_length; index++)
        put_char(&o, payload[index]);
    if (o.overflow)
        return -1;
    return finish_packet(0x30 | (retain ? 1 : 0), o.length);
}

/* ---- connection state ---- */

enum link_state { LINK_DOWN, LINK_CONNECTING, LINK_AWAIT_CONNACK, LINK_UP };

static enum link_state link = LINK_DOWN;
static int socket_fd = -1;
static u32 backoff_ms = BACKOFF_MIN_MS;
static u32 next_attempt_ms;
static u32 deadline_ms;
static u32 last_sent_ms;
static u32 last_received_ms;
static u32 last_up_ms;
static u32 receive_length;
static u8 receive_buffer[RECEIVE_MAX];

static int send_all(const u8 *data, int length)
{
    u32 started = sys_now_ms();
    int offset = 0;

    while (offset < length) {
        int count = sys_write(socket_fd, data + offset, length - offset);

        if (count == SYS_EAGAIN) {
            if (sys_now_ms() - started > 5000u)
                return -1;
            sys_wait(-1, socket_fd, 1, 200);
            continue;
        }
        if (count <= 0)
            return -1;
        offset += count;
    }
    last_sent_ms = sys_now_ms();
    return 0;
}

static void link_fail(const char *reason)
{
    if (socket_fd >= 0)
        sys_close(socket_fd);
    socket_fd = -1;
    receive_length = 0;
    link = LINK_DOWN;
    next_attempt_ms = sys_now_ms() + backoff_ms;
    if (backoff_ms < BACKOFF_MAX_MS)
        backoff_ms = backoff_ms * 2 > BACKOFF_MAX_MS ? BACKOFF_MAX_MS : backoff_ms * 2;
    logmsg(reason);
}

static int publish(const char *leaf, const char *payload, int retain)
{
    char name[96];
    int length;

    topic(name, sizeof(name), leaf);
    length = build_publish(name, payload, str_len(payload), retain);
    if (length < 0)
        return -1;
    return send_all(packet, length);
}

/* ---- device state ---- */

static int battery = -1;      /* percent, -1 unknown */
static int power_status = -1; /* raw MCU status byte */
static int usb = -1;          /* 0/1 */
static int dirty_battery, dirty_status, dirty_usb;
static int pending_buttons;
static u32 last_uptime_ms;
static int replaying = 1;
static u32 last_button_us;
static int have_last_button;

static int publish_discovery_entry(const char *component, const char *object, const char *label, const char *extra)
{
    char config_topic[128];
    struct out topic_out = { config_topic, 0, (int)sizeof(config_topic) - 1, 0 };
    char body[640];
    struct out o = { body, 0, (int)sizeof(body), 0 };
    int length;

    put_text(&topic_out, cfg.discovery);
    put_char(&topic_out, '/');
    put_text(&topic_out, component);
    put_char(&topic_out, '/');
    put_text(&topic_out, cfg.node);
    put_char(&topic_out, '/');
    put_text(&topic_out, object);
    put_text(&topic_out, "/config");
    config_topic[topic_out.length] = 0;

    put_text(&o, "{\"name\":\"");
    put_text(&o, label);
    put_text(&o, "\",\"unique_id\":\"");
    put_text(&o, cfg.node);
    put_char(&o, '_');
    put_text(&o, object);
    put_text(&o, "\",\"state_topic\":\"");
    put_text(&o, node_prefix);
    put_char(&o, '/');
    put_text(&o, object);
    put_text(&o, "\",\"availability_topic\":\"");
    put_text(&o, node_prefix);
    put_text(&o, "/availability\"");
    put_text(&o, extra);
    put_text(&o, ",\"device\":{\"identifiers\":[\"");
    put_text(&o, cfg.node);
    put_text(&o, "\"],\"name\":\"");
    put_text(&o, cfg.name);
    put_text(&o, "\",\"manufacturer\":\"RH\",\"model\":\"RH-PD10\"}}");
    if (o.overflow)
        return -1;
    length = build_publish(config_topic, body, o.length, 1);
    if (length < 0)
        return -1;
    return send_all(packet, length);
}

static int publish_discovery(void)
{
    return publish_discovery_entry("sensor", "battery", "Battery",
                                   ",\"device_class\":\"battery\",\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\"") ||
           publish_discovery_entry("binary_sensor", "external_power", "External power",
                                   ",\"device_class\":\"plug\",\"payload_on\":\"ON\",\"payload_off\":\"OFF\"") ||
           publish_discovery_entry("sensor", "power_status", "Power status",
                                   ",\"entity_category\":\"diagnostic\",\"state_class\":\"measurement\"") ||
           publish_discovery_entry("sensor", "uptime", "Uptime",
                                   ",\"device_class\":\"duration\",\"unit_of_measurement\":\"s\",\"entity_category\":\"diagnostic\",\"state_class\":\"total_increasing\"") ||
           publish_discovery_entry("event", "button", "Button",
                                   ",\"device_class\":\"button\",\"event_types\":[\"press\"]");
}

static int read_uptime_seconds(void)
{
    char text[32];
    int fd = sys_open_read(cfg.uptime, 0);
    int count;
    int seconds = 0;
    int index;

    if (fd < 0)
        return -1;
    count = sys_read(fd, text, sizeof(text) - 1);
    sys_close(fd);
    if (count <= 0)
        return -1;
    for (index = 0; index < count && text[index] >= '0' && text[index] <= '9'; index++)
        seconds = seconds * 10 + (text[index] - '0');
    return index ? seconds : -1;
}

static int publish_uptime(void)
{
    char text[16];
    struct out o = { text, 0, (int)sizeof(text) - 1, 0 };
    int seconds = read_uptime_seconds();

    if (seconds < 0)
        return 0;
    put_decimal(&o, seconds);
    text[o.length] = 0;
    return publish("uptime", text, 0);
}

static int publish_states(int everything)
{
    char text[16];
    struct out o;

    if (battery >= 0 && (everything || dirty_battery)) {
        o = (struct out){ text, 0, (int)sizeof(text) - 1, 0 };
        put_decimal(&o, battery);
        text[o.length] = 0;
        if (publish("battery", text, 1))
            return -1;
        dirty_battery = 0;
    }
    if (power_status >= 0 && (everything || dirty_status)) {
        o = (struct out){ text, 0, (int)sizeof(text) - 1, 0 };
        put_decimal(&o, power_status);
        text[o.length] = 0;
        if (publish("power_status", text, 1))
            return -1;
        dirty_status = 0;
    }
    if (usb >= 0 && (everything || dirty_usb)) {
        if (publish("external_power", usb ? "ON" : "OFF", 1))
            return -1;
        dirty_usb = 0;
    }
    return 0;
}

static int send_events(void)
{
    while (pending_buttons > 0) {
        if (publish("button", "{\"event_type\":\"press\"}", 0))
            return -1;
        pending_buttons--;
    }
    return 0;
}

/* ---- kernel log parsing ---- */

static int hex_value(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return -1;
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

/* ---- Wi-Fi watchdog (off unless wifi_watchdog=1) ---- */

static u32 last_rx_value = 0xffffffffu;
static u32 last_rx_change_ms;
static u32 last_rx_sample_ms;
static u32 last_reconnect_ms;
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

    if (!cfg.wifi_watchdog || now - last_rx_sample_ms < 5000u)
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
    /* Act only when the broker has been unreachable for a while AND no frame arrived at all. */
    if (link != LINK_UP && now - last_up_ms > 180000u && now - last_rx_change_ms > 90000u &&
        (!reconnect_done || now - last_reconnect_ms > 300000u)) {
        request_wifi_reconnect();
        reconnect_done = 1;
        last_reconnect_ms = now;
    }
}

/* ---- connection handling ---- */

static void begin_connect(u32 now)
{
    int fd = sys_tcp_start(cfg.address, cfg.port);

    if (fd < 0) {
        next_attempt_ms = now + backoff_ms;
        if (backoff_ms < BACKOFF_MAX_MS)
            backoff_ms = backoff_ms * 2 > BACKOFF_MAX_MS ? BACKOFF_MAX_MS : backoff_ms * 2;
        return;
    }
    socket_fd = fd;
    link = LINK_CONNECTING;
    deadline_ms = now + CONNECT_TIMEOUT_MS;
}

static void on_connected(u32 now)
{
    link = LINK_UP;
    backoff_ms = BACKOFF_MIN_MS;
    last_up_ms = now;
    last_received_ms = now;
    logmsg("connected");
    if (publish_discovery() || publish("availability", "online", 1) || publish_states(1) || publish_uptime())
        link_fail("publish failed after connect");
    last_uptime_ms = now;
}

/* Consumes complete packets from the receive buffer. */
static void process_receive(u32 now)
{
    u32 offset = 0;

    while (receive_length - offset >= 2) {
        u32 length = 0;
        u32 multiplier = 1;
        u32 index = offset + 1;
        u32 header;
        u32 total;
        int type;

        for (;;) {
            u8 digit;

            if (index >= receive_length)
                goto compact; /* length bytes not complete yet */
            digit = receive_buffer[index++];
            length += (u32)(digit & 0x7f) * multiplier;
            multiplier *= 128u;
            if (!(digit & 0x80))
                break;
            if (multiplier > 128u * 128u * 128u) {
                link_fail("malformed packet");
                return;
            }
        }
        header = index - offset;
        total = header + length;
        if (total > RECEIVE_MAX) {
            link_fail("packet too large");
            return;
        }
        if (receive_length - offset < total)
            break;
        type = receive_buffer[offset] >> 4;
        last_received_ms = now;
        if (type == 2) { /* CONNACK */
            if (length >= 2 && receive_buffer[offset + header + 1] == 0) {
                on_connected(now);
                /* A failed first publish has already reset the buffer; do not touch it again. */
                if (link == LINK_DOWN)
                    return;
            } else {
                link_fail("broker refused the connection");
                return;
            }
        }
        offset += total;
    }
compact:
    if (offset) {
        u32 remaining = receive_length - offset;
        u32 index;

        for (index = 0; index < remaining; index++)
            receive_buffer[index] = receive_buffer[offset + index];
        receive_length = remaining;
    }
}

static void read_socket(u32 now)
{
    for (;;) {
        int count = sys_read(socket_fd, receive_buffer + receive_length, (int)(RECEIVE_MAX - receive_length));

        if (count == SYS_EAGAIN)
            return;
        if (count <= 0) {
            link_fail("connection closed");
            return;
        }
        receive_length += (u32)count;
        process_receive(now);
        if (link == LINK_DOWN || receive_length >= RECEIVE_MAX)
            return;
    }
}

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
        next_attempt_ms = now;
    }
    logmsg("started");

    for (;;) {
        u32 now = sys_now_ms();
        int wait_ms = 1000;

        drain_kmsg(kmsg_fd);
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
            if (now - last_uptime_ms >= UPTIME_PERIOD_MS) {
                last_uptime_ms = now;
                if (publish_uptime()) {
                    link_fail("publish failed");
                    break;
                }
            }
            if (now - last_sent_ms >= (u32)cfg.keepalive * 500u) {
                static const u8 ping[2] = { 0xc0, 0 };

                if (send_all(ping, 2)) {
                    link_fail("keepalive failed");
                    break;
                }
            }
            if (now - last_received_ms > (u32)cfg.keepalive * 1500u)
                link_fail("broker stopped answering");
            break;
        }
        watchdog(now);
        if (link == LINK_DOWN) {
            int until = (int)(next_attempt_ms - now);

            wait_ms = until < 0 ? 0 : (until < 1000 ? until : 1000);
        }
        sys_wait(kmsg_fd, socket_fd, link == LINK_CONNECTING, wait_ms > 0 ? wait_ms : 1);
    }
}
