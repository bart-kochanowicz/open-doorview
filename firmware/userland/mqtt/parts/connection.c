/* Connecting to the broker, the receive path and the reconnect back-off.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

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
        } else if (type == 3)
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
