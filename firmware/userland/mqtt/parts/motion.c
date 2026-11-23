/* Motion: Majestic's motion counter and the motion entity.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

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
    if (cfg.motion_video) {
        update_motion(now);
    } else {
        /* Only the PIR reports motion: just let the hold run out. */
        if (motion_state < 0)
            motion_state = 0;
        if (motion_state == 1 && (int)(now - motion_until_ms) >= 0)
            motion_state = 0;
    }
    if (motion_state != previous)
        dirty_motion = 1;
    if (motion_state == 1)
        activity_seen = 1;
    if (cfg.snapshot && previous == 0 && motion_state == 1) {
        u32 edge = sys_now_ms();

        snapshot_pending = 1;
        snapshot_due_ms = edge + (u32)cfg.snapshot_delay_ms;
        snapshot_deadline_ms = edge + SNAPSHOT_PENDING_MS;
    }
}
