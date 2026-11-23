/* doorview-mqtt: publishes RH-PD10 battery, USB power, button presses and uptime to MQTT
 * (Home Assistant discovery). It follows the kernel log written by the syslink driver:
 *   doorview_power: command=a2 ... payload=SS UU CC CC   MCU PowerInfo: status, usb, capacity
 *   doorview_control: command=a5 length=8                button
 * With motion=1 it also polls Majestic's motion counter on the loopback interface (see fetch_motion_total), and with
 * snapshot=1 it publishes a JPEG from Majestic when motion starts, so Home Assistant never has to reach the camera.
 * With live=1 it subscribes to doorview/<node>/live/set and, on ON, publishes small pictures to doorview/<node>/live for
 * live_seconds (a slide show on demand); OFF or the time running out ends it.
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
#define MOTION_POLL_MS 1000u
#define MOTION_IO_MS 300u
#define METRICS_MAX 4096
#define SNAPSHOT_MAX 327680 /* largest JPEG published; a 1920x1080 picture is about 120 to 250 KB */
#define SNAPSHOT_RESPONSE_MAX (SNAPSHOT_MAX + 1024) /* HTTP headers included */
#define SNAPSHOT_HEAD 256 /* room in front of the response for the MQTT header */
#define SNAPSHOT_IO_MS 5000u
#define SNAPSHOT_PENDING_MS 10000u

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
    int snapshot_delay_ms;
    int live;
    int live_seconds;
    int live_interval_ms;
    char live_path[128];
    char snapshot_path[128];
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

/* A request path that cannot smuggle a second header line into the GET: no spaces or control characters. */
static int valid_path(const char *text)
{
    int index;

    if (text[0] != '/')
        return 0;
    for (index = 0; text[index]; index++) {
        char c = text[index];

        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
            c == '/' || c == '.' || c == '_' || c == '-' || c == '?' || c == '&' || c == '=' || c == '%')
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
    cfg.motion_hold = 10;
    cfg.motion_window = 3;
    cfg.live_seconds = 30;
    cfg.live_interval_ms = 500;
    str_copy(cfg.live_path, sizeof(cfg.live_path), "/image.jpg?width=640&height=360&qfactor=40");
    cfg.snapshot_cooldown = 30;
    str_copy(cfg.snapshot_path, sizeof(cfg.snapshot_path), "/image.jpg?qfactor=60");
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
        } else if (str_eq(line, "snapshot_cooldown")) {
            if (!parse_number(value, &number) || number < 1 || number > 3600)
                return -13;
            cfg.snapshot_cooldown = number;
        }
    }
    if (cfg.snapshot && !cfg.motion)
        return -14; /* the snapshot is taken when motion starts */
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
static u32 last_ping_ms;
static u32 receive_length;
static u32 skip_bytes; /* the rest of an oversized PUBLISH that is being dropped */
static u8 receive_buffer[RECEIVE_MAX];

/* Gives up after 5 s without progress, not 5 s in all: a 150 KB picture over a slow link may take longer. */
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
        started = sys_now_ms();
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
    skip_bytes = 0;
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
static int motion_state = -1; /* 0/1, -1 until the first successful poll */
static int dirty_motion;
static int dirty_live;
static int live_active; /* a live view is running */
static int have_motion_total;
static u32 motion_total;
static u32 motion_until_ms;
static u32 last_motion_poll_ms;

/* The last readings of the counter, newest last, to measure how fast it rises over motion_window seconds. */
#define MOTION_SAMPLES 16
static struct {
    u32 at_ms;
    u32 total;
} motion_samples[MOTION_SAMPLES];
static int motion_sample_head; /* next slot to write */
static int motion_sample_count;
static char metrics[METRICS_MAX];
static u8 snapshot_buffer[SNAPSHOT_HEAD + SNAPSHOT_RESPONSE_MAX];
static int snapshot_pending;
static int have_snapshot;
static u32 snapshot_deadline_ms;
static u32 motion_settle_until_ms; /* no rise counts before this: motion_settle seconds after the start or a Majestic restart */
static u32 snapshot_due_ms; /* not before this: the picture is taken snapshot_delay_ms after the motion edge */
static u32 last_snapshot_ms;

static int publish_discovery_entry(const char *component, const char *object, const char *label, const char *state_key,
                                   const char *extra)
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
    put_text(&o, "\",\"");
    put_text(&o, state_key);
    put_text(&o, "\":\"");
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
    return publish_discovery_entry("sensor", "battery", "Battery", "state_topic",
                                   ",\"device_class\":\"battery\",\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\"") ||
           publish_discovery_entry("binary_sensor", "external_power", "External power", "state_topic",
                                   ",\"device_class\":\"plug\",\"payload_on\":\"ON\",\"payload_off\":\"OFF\"") ||
           publish_discovery_entry("sensor", "power_status", "Power status", "state_topic",
                                   ",\"entity_category\":\"diagnostic\",\"state_class\":\"measurement\"") ||
           publish_discovery_entry("sensor", "uptime", "Uptime", "state_topic",
                                   ",\"device_class\":\"duration\",\"unit_of_measurement\":\"s\",\"entity_category\":\"diagnostic\",\"state_class\":\"total_increasing\"") ||
           publish_discovery_entry("event", "button", "Button", "state_topic",
                                   ",\"device_class\":\"button\",\"event_types\":[\"press\"]") ||
           (cfg.motion && publish_discovery_entry("binary_sensor", "motion", "Motion", "state_topic",
                                                  ",\"device_class\":\"motion\",\"payload_on\":\"ON\",\"payload_off\":\"OFF\"")) ||
           (cfg.snapshot && publish_discovery_entry("image", "snapshot", "Snapshot", "image_topic",
                                                    ",\"content_type\":\"image/jpeg\""));
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
    if (motion_state >= 0 && (everything || dirty_motion)) {
        if (publish("motion", motion_state ? "ON" : "OFF", 1))
            return -1;
        dirty_motion = 0;
    }
    if (cfg.live && (everything || dirty_live)) {
        if (publish("live/state", live_active ? "ON" : "OFF", 1))
            return -1;
        dirty_live = 0;
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

/* ---- motion ---- */

/* Reads the value of Majestic's md_rects_acc_total (rectangles the hardware motion detector reported inside the
 * region of interest) from http://127.0.0.1:<motion_port>/metrics/motion. Requests from the camera itself need no
 * password. One short exchange on a fresh socket, bounded by MOTION_IO_MS, stopped as soon as the line is complete.
 * Returns 0 and the value, or -1 when Majestic does not answer or has no such counter (motion detection is off). */
static int parse_motion_total(const char *text, int length, u32 *total)
{
    static const char key[] = "\nmd_rects_acc_total ";
    const char *at = find_text(text, length, key);
    u32 value = 0;
    int digits = 0;

    if (!at)
        return -1;
    at += sizeof(key) - 1;
    while (at < text + length && *at >= '0' && *at <= '9') {
        if (++digits > 9)
            return -1;
        value = value * 10u + (u32)(*at - '0');
        at++;
    }
    /* The line must be complete, or a partial read would look like a smaller counter. */
    if (!digits || at >= text + length || (*at != '\n' && *at != '\r'))
        return -1;
    *total = value;
    return 0;
}

/* One HTTP/1.0 GET to Majestic on the loopback interface, bounded by io_ms. Reads the whole answer (headers
 * included) into buffer, or stops early once done() says it has what it needs. Returns the number of bytes read, or
 * -1 when the connection or the request fails. A full buffer is the caller's to interpret. */
static int http_get(const char *path, u8 *buffer, int capacity, u32 io_ms, int (*done)(const u8 *, int))
{
    char request[256];
    struct out o = { request, 0, (int)sizeof(request), 0 };
    u32 started = sys_now_ms();
    int length = 0;
    int result = -1;
    int status;
    int fd;

    put_text(&o, "GET ");
    put_text(&o, path);
    put_text(&o, " HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    if (o.overflow)
        return -1;
    fd = sys_tcp_start(0x7f000001u, (u16)cfg.motion_port);
    if (fd < 0)
        return -1;
    while ((status = sys_tcp_status(fd)) == 1) {
        if (sys_now_ms() - started > io_ms)
            goto finish;
        sys_wait(-1, fd, 1, 20);
    }
    if (status != 0 || sys_write(fd, request, o.length) != o.length)
        goto finish;
    result = 0;
    while (length < capacity) {
        int count = sys_read(fd, buffer + length, capacity - length);

        if (count == SYS_EAGAIN) {
            if (sys_now_ms() - started > io_ms)
                break;
            sys_wait(-1, fd, 0, 20);
            continue;
        }
        if (count <= 0)
            break;
        length += count;
        if (done && done(buffer, length))
            break;
    }
    result = length;
finish:
    sys_close(fd);
    return result;
}

static int metrics_done(const u8 *text, int length)
{
    u32 ignored;

    return !parse_motion_total((const char *)text, length, &ignored);
}

static int fetch_motion_total(u32 *total)
{
    int length = http_get("/metrics/motion", (u8 *)metrics, METRICS_MAX - 1, MOTION_IO_MS, metrics_done);

    return length > 0 ? parse_motion_total(metrics, length, total) : -1;
}

static void note_motion_sample(u32 now, u32 total)
{
    motion_samples[motion_sample_head].at_ms = now;
    motion_samples[motion_sample_head].total = total;
    motion_sample_head = (motion_sample_head + 1) % MOTION_SAMPLES;
    if (motion_sample_count < MOTION_SAMPLES)
        motion_sample_count++;
}

/* Whether the counter rose by at least motion_min_rate rectangles per second over the newest stretch that is at least
 * motion_window seconds long (the span ends at the sample just noted). False while there is not that much history yet.
 * No division: the freestanding ARM build has no divide helper, so the rate is compared as delta * 1000 against
 * min_rate * age; the clamps keep both products below 2^32. */
static int motion_fast_enough(u32 now, u32 total)
{
    int back;

    for (back = 2; back <= motion_sample_count; back++) {
        int slot = (motion_sample_head - back + 2 * MOTION_SAMPLES) % MOTION_SAMPLES;
        u32 age = now - motion_samples[slot].at_ms;

        if (age >= (u32)cfg.motion_window * 1000u) {
            u32 delta = total - motion_samples[slot].total;

            if (delta > 1000000u)
                delta = 1000000u;
            if (age > 100000u)
                age = 100000u;
            return delta * 1000u >= (u32)cfg.motion_min_rate * age;
        }
    }
    return 0;
}

/* Turns the counter into a binary sensor: ON when it rises, OFF motion_hold seconds after the last rise. With
 * motion_min_rate it must rise by at least that many rectangles per second over motion_window seconds, which keeps the
 * detector's own noise in the dark from holding the sensor on. A counter that goes down means Majestic restarted: take
 * it as the new baseline (and forget the history) instead of as motion. */
static void update_motion(u32 now)
{
    u32 total;
    int rise;

    if (motion_state == 1 && (int)(now - motion_until_ms) >= 0)
        motion_state = 0;
    if (now - last_motion_poll_ms < MOTION_POLL_MS)
        return;
    last_motion_poll_ms = now;
    if (fetch_motion_total(&total))
        return;
    now = sys_now_ms();
    if (motion_state < 0)
        motion_state = 0;
    if (have_motion_total && total < motion_total) {
        motion_sample_count = 0;
        motion_settle_until_ms = now + (u32)cfg.motion_settle * 1000u;
    }
    note_motion_sample(now, total);
    if (cfg.motion_min_rate > 0)
        rise = have_motion_total && motion_fast_enough(now, total);
    else
        rise = have_motion_total && total > motion_total;
    if ((int)(now - motion_settle_until_ms) < 0)
        rise = 0; /* the detector and the night switch settle for a while after a start */
    if (rise) {
        motion_until_ms = now + (u32)cfg.motion_hold * 1000u;
        motion_state = 1;
    }
    motion_total = total;
    have_motion_total = 1;
}

/* Only a real change is published: a hold that runs out in the same pass as a new rise stays ON. */
static void poll_motion(u32 now)
{
    int previous = motion_state;

    if (!cfg.motion)
        return;
    update_motion(now);
    if (motion_state != previous)
        dirty_motion = 1;
    if (cfg.snapshot && previous == 0 && motion_state == 1) {
        u32 edge = sys_now_ms();

        snapshot_pending = 1;
        snapshot_due_ms = edge + (u32)cfg.snapshot_delay_ms;
        snapshot_deadline_ms = edge + SNAPSHOT_PENDING_MS;
    }
}

/* ---- snapshot ---- */

/* The JPEG is read into snapshot_buffer after SNAPSHOT_HEAD spare bytes, and the MQTT header is written backwards
 * from the start of the image, so a 12 KB picture is never copied. Returns the first byte of the packet. */
static u8 *write_publish_header(u8 *payload, int payload_length, const char *topic_name, int retain, int *packet_length)
{
    int topic_length = str_len(topic_name);
    int remaining = 2 + topic_length + payload_length;
    u8 digits[3];
    int count = 0;
    int index;
    u8 *at = payload;

    at -= topic_length;
    for (index = 0; index < topic_length; index++)
        at[index] = (u8)topic_name[index];
    at -= 2;
    at[0] = (u8)(topic_length >> 8);
    at[1] = (u8)(topic_length & 0xff);
    do {
        u8 digit = (u8)(remaining & 0x7f);

        remaining >>= 7;
        if (remaining)
            digit |= 0x80;
        digits[count++] = digit;
    } while (remaining && count < 3);
    for (index = count - 1; index >= 0; index--)
        *--at = digits[index];
    *--at = (u8)(0x30 | (retain ? 1 : 0));
    *packet_length = (int)(payload + payload_length - at);
    return at;
}

/* Finds the picture in an HTTP answer: status 200, and a JPEG that starts with SOI and ends with EOI, so a
 * half-read or error page is never published. Returns the offset of the body or -1. */
static int find_jpeg(const u8 *data, int length, int *body_length)
{
    const char *text = (const char *)data;
    const char *end = find_text(text, length, "\r\n\r\n");
    int offset;
    int size;

    if (!end || length < 12 || !find_text(text, 16, "HTTP/1.") || !find_text(text, length < 32 ? length : 32, " 200 "))
        return -1;
    offset = (int)(end - text) + 4;
    size = length - offset;
    if (size < 4 || data[offset] != 0xff || data[offset + 1] != 0xd8 || data[length - 2] != 0xff || data[length - 1] != 0xd9)
        return -1;
    *body_length = size;
    return offset;
}

/* Returns 0 when the picture was published or skipped, -1 when the MQTT socket failed. */
static int take_snapshot(void)
{
    char name[96];
    u8 *response = snapshot_buffer + SNAPSHOT_HEAD;
    int length = http_get(cfg.snapshot_path, response, SNAPSHOT_RESPONSE_MAX, SNAPSHOT_IO_MS, 0);
    int body_length = 0;
    int offset;
    int packet_length;
    u32 sent_at;
    u8 *start;

    if (length < 0) {
        logmsg("snapshot: Majestic does not answer");
        return 0;
    }
    if (length >= SNAPSHOT_RESPONSE_MAX) {
        logmsg("snapshot: picture too large");
        return 0;
    }
    offset = find_jpeg(response, length, &body_length);
    if (offset < 0 || body_length > SNAPSHOT_MAX) {
        logmsg("snapshot: not a complete JPEG");
        return 0;
    }
    topic(name, sizeof(name), "snapshot");
    start = write_publish_header(response + offset, body_length, name, 1, &packet_length);
    sent_at = sys_now_ms();
    if (send_all(start, packet_length))
        return -1;
    {
        char text[64];
        struct out o = { text, 0, (int)sizeof(text) - 1, 0 };

        put_text(&o, "snapshot published, ");
        put_decimal(&o, body_length);
        put_text(&o, " bytes in ");
        put_decimal(&o, (int)(sys_now_ms() - sent_at));
        put_text(&o, " ms");
        text[o.length] = 0;
        logmsg(text);
    }
    return 0;
}

/* ---- live view ---- */

static u32 live_deadline_ms;
static u32 live_next_ms;
static u32 live_frames;
static u32 live_bytes;
static u32 live_started_ms;
static int live_warned; /* a picture that Majestic could not give was already logged in this view */
static char live_set_topic[96]; /* doorview/<node>/live/set */

static void live_start(u32 now)
{
    if (!live_active) {
        live_active = 1;
        live_frames = 0;
        live_bytes = 0;
        live_started_ms = now;
        live_warned = 0;
        live_next_ms = now;
        dirty_live = 1;
        logmsg("live view started");
    }
    live_deadline_ms = now + (u32)cfg.live_seconds * 1000u;
}

static void live_stop(void)
{
    char text[96];
    struct out o = { text, 0, (int)sizeof(text) - 1, 0 };

    if (!live_active)
        return;
    live_active = 0;
    dirty_live = 1;
    put_text(&o, "live view ended, ");
    put_decimal(&o, (int)live_frames);
    put_text(&o, " pictures, ");
    put_decimal(&o, (int)live_bytes);
    put_text(&o, " bytes in ");
    put_decimal(&o, (int)(sys_now_ms() - live_started_ms));
    put_text(&o, " ms");
    text[o.length] = 0;
    logmsg(text);
}

/* Publishes one small picture, not retained. Returns -1 only when the MQTT socket failed. */
static int take_live_frame(void)
{
    char name[96];
    u8 *response = snapshot_buffer + SNAPSHOT_HEAD;
    int length = http_get(cfg.live_path, response, SNAPSHOT_RESPONSE_MAX, SNAPSHOT_IO_MS, 0);
    int body_length = 0;
    int offset = -1;
    int packet_length;
    u8 *start;

    if (length >= 0 && length < SNAPSHOT_RESPONSE_MAX)
        offset = find_jpeg(response, length, &body_length);
    if (offset < 0 || body_length > SNAPSHOT_MAX) {
        if (!live_warned) {
            live_warned = 1;
            logmsg("live view: no usable picture from Majestic");
        }
        return 0;
    }
    topic(name, sizeof(name), "live");
    start = write_publish_header(response + offset, body_length, name, 0, &packet_length);
    if (send_all(start, packet_length))
        return -1;
    live_frames++;
    live_bytes += (u32)body_length;
    return 0;
}

/* A PUBLISH from the broker. Only an ON or OFF on the command topic counts, and only when it is live and not retained:
 * a retained ON would otherwise start a view on every reconnect. */
static void handle_incoming_publish(u32 offset, u32 header, u32 length, u32 now)
{
    int flags = receive_buffer[offset] & 0x0f;
    const u8 *body = receive_buffer + offset + header;
    u32 topic_length;
    u32 payload;
    u32 index;

    if (!cfg.live || (flags & 0x01) || (flags & 0x06) || length < 2)
        return;
    topic_length = ((u32)body[0] << 8) | body[1];
    if (2 + topic_length > length || topic_length != (u32)str_len(live_set_topic))
        return;
    for (index = 0; index < topic_length; index++)
        if (body[2 + index] != (u8)live_set_topic[index])
            return;
    payload = 2 + topic_length;
    if (length - payload == 2 && body[payload] == 'O' && body[payload + 1] == 'N')
        live_start(now);
    else if (length - payload == 3 && body[payload] == 'O' && body[payload + 1] == 'F' && body[payload + 2] == 'F')
        live_stop();
}

static int send_subscribe(void)
{
    struct out o = { (char *)packet + 5, 0, PACKET_MAX - 5, 0 };

    put_byte(&o, 0); /* packet identifier */
    put_byte(&o, 1);
    put_string16(&o, live_set_topic);
    put_byte(&o, 0); /* QoS 0 */
    if (o.overflow)
        return -1;
    return send_all(packet, finish_packet(0x82, o.length));
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
    last_ping_ms = now;
    logmsg("connected");
    live_active = 0; /* a clean session: nothing was subscribed and no view runs */
    if (publish_discovery() || publish("availability", "online", 1) || publish_states(1) || publish_uptime())
        link_fail("publish failed after connect");
    else if (cfg.live && send_subscribe())
        link_fail("subscribe failed");
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
            if ((receive_buffer[offset] >> 4) == 3) {
                /* A PUBLISH too large to keep, for example a big payload on the command topic: drop it as it
                 * arrives instead of letting anyone who can publish there disconnect the camera. */
                skip_bytes = total - (receive_length - offset);
                offset = receive_length;
                last_received_ms = now;
                goto compact;
            }
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
        else if (type == 3)
            handle_incoming_publish(offset, header, length, now);
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
        int count;

        if (skip_bytes) {
            count = sys_read(socket_fd, receive_buffer, (int)(skip_bytes < RECEIVE_MAX ? skip_bytes : RECEIVE_MAX));
            if (count == SYS_EAGAIN)
                return;
            if (count <= 0) {
                link_fail("connection closed");
                return;
            }
            skip_bytes -= (u32)count;
            last_received_ms = now;
            continue;
        }
        count = sys_read(socket_fd, receive_buffer + receive_length, (int)(RECEIVE_MAX - receive_length));
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
    }
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
            if (snapshot_pending && (int)(now - snapshot_due_ms) >= 0) {
                int expired = (int)(now - snapshot_deadline_ms) >= 0;
                int cooling = have_snapshot && now - last_snapshot_ms < (u32)cfg.snapshot_cooldown * 1000u;

                snapshot_pending = 0;
                if (!expired && !cooling) {
                    last_snapshot_ms = now;
                    have_snapshot = 1;
                    if (take_snapshot()) {
                        link_fail("publish failed");
                        break;
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
                (now - last_received_ms >= (u32)cfg.keepalive * 500u && now - last_ping_ms >= (u32)cfg.keepalive * 500u)) {
                static const u8 ping[2] = { 0xc0, 0 };

                last_ping_ms = now;
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
