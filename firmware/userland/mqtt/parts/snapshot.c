/* The snapshot on a motion edge, and the wait for night mode before it.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

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
    if (size < 4 || data[offset] != 0xff || data[offset + 1] != 0xd8 || data[length - 2] != 0xff ||
        data[length - 1] != 0xd9)
        return -1;
    *body_length = size;
    return offset;
}

/* Returns 0 when the picture was published or skipped, -1 when the MQTT socket failed. */
static int snapshot_retry_logged;

/* ---- night mode before the picture ---- */

/* One value of Majestic's /metrics/night ("\n<key> <integer>\n"); the integer may be negative (-1 = not measured). */
static int parse_metric(const char *text, int length, const char *key, int *value)
{
    char pattern[48];
    struct out o = { pattern, 0, (int)sizeof(pattern) - 1, 0 };
    const char *at;
    int negative = 0;
    int digits = 0;
    int result = 0;

    put_text(&o, "\n");
    put_text(&o, key);
    put_text(&o, " ");
    if (o.overflow)
        return -1;
    pattern[o.length] = 0;
    at = find_text(text, length, pattern);
    if (!at)
        return -1;
    at += o.length;
    if (at < text + length && *at == '-') {
        negative = 1;
        at++;
    }
    while (at < text + length && *at >= '0' && *at <= '9') {
        if (++digits > 9)
            return -1;
        result = result * 10 + (*at - '0');
        at++;
    }
    if (!digits || at >= text + length || (*at != '\n' && *at != '\r'))
        return -1;
    *value = negative ? -result : result;
    return 0;
}

static u32 night_wait_started_ms;
static int night_waiting; /* this picture is already waiting for night mode */

/* Whether the picture may be taken now. It waits while the light has not been measured (gain -1) or Majestic is
 * counting toward night, never longer than night_wait_ms, and never when Majestic does not answer or has no such
 * metrics (the picture's own retry covers a Majestic that is still starting). */
static int night_ready(u32 now)
{
    int length;
    int enabled;
    int gain;
    int pending;

    if (!cfg.night_wait_ms)
        return 1;
    length = http_get("/metrics/night", (u8 *)metrics, METRICS_MAX - 1, MOTION_IO_MS, 0);
    if (length <= 0 || parse_metric(metrics, length, "night_enabled", &enabled) ||
        parse_metric(metrics, length, "night_auto_gain_milli", &gain) ||
        parse_metric(metrics, length, "night_auto_pending", &pending))
        return 1;
    if (enabled || (gain >= 0 && pending != 1))
        return 1;
    if (!night_waiting) {
        night_waiting = 1;
        night_wait_started_ms = now;
        logmsg("snapshot: waiting for night mode");
        return 0;
    }
    if (now - night_wait_started_ms >= (u32)cfg.night_wait_ms) {
        logmsg("snapshot: night mode did not come in time");
        return 1;
    }
    return 0;
}

/* Returns 0 when done (published or not a usable picture), 1 when Majestic does not answer yet, -1 when MQTT failed. */
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
        /* Majestic may still be starting after a wake-up: the caller tries again until the picture is due no more. */
        if (!snapshot_retry_logged) {
            snapshot_retry_logged = 1;
            logmsg("snapshot: Majestic does not answer");
        }
        return 1;
    }
    snapshot_retry_logged = 0;
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
    activity_seen = 1;
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
