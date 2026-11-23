/* The live view: small pictures on demand.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

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
        activity_seen = 1;
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
    activity_seen = 1;
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
