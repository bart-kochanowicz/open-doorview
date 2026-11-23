/* MQTT 3.1.1 packets and the connection state.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

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
