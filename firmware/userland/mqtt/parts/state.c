/* The device state (battery, USB power, buttons, uptime) and Home Assistant discovery.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

static int battery = -1; /* percent, -1 unknown */
static int power_status = -1; /* raw MCU status byte */
static int usb = -1; /* 0/1 */
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
/* Something happened that keeps the camera awake: motion, a button press, a PIR alarm, a picture, a live view. */
static int activity_seen;
static int have_snapshot;
static u32 snapshot_deadline_ms;
/* No rise counts before this: motion_settle seconds after the start or a Majestic restart. */
static u32 motion_settle_until_ms;
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
    return publish_discovery_entry(
               "sensor", "battery", "Battery", "state_topic",
               ",\"device_class\":\"battery\",\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\"") ||
           publish_discovery_entry("binary_sensor", "external_power", "External power", "state_topic",
                                   ",\"device_class\":\"plug\",\"payload_on\":\"ON\",\"payload_off\":\"OFF\"") ||
           publish_discovery_entry("sensor", "power_status", "Power status", "state_topic",
                                   ",\"entity_category\":\"diagnostic\",\"state_class\":\"measurement\"") ||
           publish_discovery_entry("sensor", "uptime", "Uptime", "state_topic",
                                   ",\"device_class\":\"duration\",\"unit_of_measurement\":\"s\",\"entity_category\":"
                                   "\"diagnostic\",\"state_class\":\"total_increasing\"") ||
           publish_discovery_entry("event", "button", "Button", "state_topic",
                                   ",\"device_class\":\"button\",\"event_types\":[\"press\"]") ||
           (cfg.motion &&
            publish_discovery_entry("binary_sensor", "motion", "Motion", "state_topic",
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
