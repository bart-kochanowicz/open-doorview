/* Sleep, the wake-up reason and the PIR setup.
 * Part of doorview-mqtt.c, which #includes the parts in order: the daemon stays one translation unit and builds to
 * the same binary as before the split. A part does not compile on its own. */

#define SLEEP_PIR_SETTLE_MS 100u
#define SLEEP_POWER_OFF_WAIT_MS 30000u
#define SLEEP_RETRY_MS 300000u

static u32 last_activity_ms;
static u32 sleep_retry_ms;
static int wake_pir_pending;
static int sleep_logged_skip;

/* The syslink driver takes one coprocessor command at a time and answers a second one with EBUSY until the first is sent
 * (a fraction of a second): such a write is tried again for up to a second. */
static int write_text(const char *path, const char *text)
{
    int attempt;

    for (attempt = 0; attempt < 20; attempt++) {
        int fd = sys_open_write(path);
        int result;

        if (fd < 0)
            return -1;
        result = sys_write(fd, text, str_len(text));
        sys_close(fd);
        if (result == str_len(text))
            return 0;
        if (result != -16) /* EBUSY */
            return -1;
        sys_wait(-1, -1, 0, 50);
    }
    return -1;
}

/* The syslink_poll parameter holds the reason the coprocessor gave for starting the SoC ("pir", "key", "poweron"...). */
static void read_wake_reason(void)
{
    char reason[24];
    char text[64];
    struct out o = { text, 0, (int)sizeof(text) - 1, 0 };
    int fd = sys_open_read(cfg.reason_file, 0);
    int count = 0;
    int index;

    if (fd < 0)
        return;
    count = sys_read(fd, reason, (int)sizeof(reason) - 1);
    sys_close(fd);
    if (count <= 0)
        return;
    for (index = 0; index < count && reason[index] > ' ' && reason[index] <= '~'; index++)
        ;
    reason[index] = 0;
    if (!reason[0])
        return;
    put_text(&o, "wake-up reason: ");
    put_text(&o, reason);
    text[o.length] = 0;
    logmsg(text);
    wake_pir_pending = str_eq(reason, "pir");
}

/* A PIR wake-up (motion before Linux was up) or alarm (while awake) is a motion edge with a snapshot; one that arrives
 * while motion is already reported only extends the hold. */
static void report_pir_motion(u32 now)
{
    int edge = motion_state != 1;

    wake_pir_pending = 0;
    pir_alarm_pending = 0;
    motion_state = 1;
    motion_until_ms = now + (u32)cfg.motion_hold * 1000u;
    if (edge) {
        dirty_motion = 1;
        if (cfg.snapshot) {
            snapshot_pending = 1;
            snapshot_due_ms = now + (u32)cfg.snapshot_delay_ms;
            snapshot_deadline_ms = now + SNAPSHOT_PENDING_MS;
        }
    }
    last_activity_ms = now;
}

static int sleep_blocked(void)
{
    int fd;

    if (live_active || snapshot_pending || motion_state == 1 || pending_buttons > 0 || wake_pir_pending ||
        pir_alarm_pending)
        return 1;
    if (dirty_battery || dirty_status || dirty_usb || dirty_motion || dirty_live)
        return 1;
    /* The first power frame has not arrived: do not guess whether the camera is on a charger. */
    if (usb < 0 || (usb && !cfg.sleep_usb))
        return 1;
    fd = sys_open_read(cfg.stay_awake_file, 1);
    if (fd >= 0) {
        sys_close(fd);
        return 1;
    }
    return 0;
}

/* The text for the mcu parameter that sets the coprocessor's wake-up timer: 7b and the seconds as four bytes, little endian. */
static void wake_timer_text(int seconds, char *text)
{
    static const char digits[] = "0123456789abcdef";
    int index;

    text[0] = '7';
    text[1] = 'b';
    for (index = 0; index < 4; index++) {
        u32 byte = ((u32)seconds >> (8 * index)) & 0xffu;

        text[2 + 2 * index] = digits[byte >> 4];
        text[3 + 2 * index] = digits[byte & 15u];
    }
    text[10] = '\n';
    text[11] = 0;
}

/* The text for the mcu parameter that sets the PIR sensitivity: 79 and the level in the high byte of a u16. */
static void pir_sensitivity_text(int level, char *text)
{
    text[0] = '7';
    text[1] = '9';
    text[2] = '0';
    text[3] = '0';
    text[4] = '0';
    text[5] = (char)('0' + level);
    text[6] = '\n';
    text[7] = 0;
}

/* The sensitivity (when set) and the PIR on, written to the mcu parameter once the connection is up. */
static int pir_setup_done;

static void pir_setup(void)
{
    char text[8];

    pir_setup_done = 1;
    if (cfg.pir_sensitivity) {
        pir_sensitivity_text(cfg.pir_sensitivity, text);
        if (write_text(cfg.mcu_parameter, text) < 0)
            logmsg("PIR sensitivity refused by the driver");
        sys_wait(-1, -1, 0, (int)SLEEP_PIR_SETTLE_MS);
    }
    if (write_text(cfg.mcu_parameter, "780100\n") < 0)
        logmsg("PIR switch refused by the driver");
    else
        logmsg("PIR is on");
    sys_wait(-1, -1, 0, (int)SLEEP_PIR_SETTLE_MS);
}

/* The factory order: wake timer, PIR on, sync, then the driver sends 8a:77 07 and 9a:03 and answers the coprocessor's 0xa0.
 * The coprocessor wakes the SoC by its own timer, observed as every 5 minutes, unless it is told otherwise (wake_timer=0). */
static void maybe_sleep(u32 now)
{
    static const u8 disconnect[2] = { 0xe0, 0 };
    u32 waited;

    if (cfg.sleep_after <= 0 || link != LINK_UP || (int)(now - sleep_retry_ms) < 0)
        return;
    if (activity_seen) {
        activity_seen = 0;
        last_activity_ms = now;
    }
    if (now - last_activity_ms < (u32)cfg.sleep_after * 1000u)
        return;
    if (sleep_blocked()) {
        if (!sleep_logged_skip) {
            sleep_logged_skip = 1;
            logmsg("sleep postponed: the camera is busy, on a charger or kept awake");
        }
        return;
    }
    sleep_logged_skip = 0;
    logmsg("going to sleep");
    /* Home Assistant is told at once instead of after the keepalive; the connection ends cleanly. */
    if (publish("availability", "offline", 1) || send_all(disconnect, 2)) {
        link_fail("publish failed");
        return;
    }
    {
        char timer[12];

        wake_timer_text(cfg.wake_timer, timer);
        if (write_text(cfg.mcu_parameter, timer) < 0)
            logmsg("wake timer refused by the driver: the coprocessor keeps its own timer");
        sys_wait(-1, -1, 0, (int)SLEEP_PIR_SETTLE_MS);
    }
    if (cfg.pir_sensitivity) {
        char level[8];

        pir_sensitivity_text(cfg.pir_sensitivity, level);
        if (write_text(cfg.mcu_parameter, level) < 0)
            logmsg("PIR sensitivity refused by the driver");
        sys_wait(-1, -1, 0, (int)SLEEP_PIR_SETTLE_MS);
    }
    if (write_text(cfg.mcu_parameter, "780100\n") < 0) {
        logmsg("sleep refused: cannot switch the PIR on");
        sleep_retry_ms = now + SLEEP_RETRY_MS;
        link_fail("sleep refused");
        return;
    }
    sys_wait(-1, -1, 0, (int)SLEEP_PIR_SETTLE_MS);
    sys_sync();
    if (write_text(cfg.standby_parameter, "1\n") < 0) {
        logmsg("sleep refused: cannot start the standby");
        sleep_retry_ms = now + SLEEP_RETRY_MS;
        link_fail("sleep refused");
        return;
    }
    /* The coprocessor cuts the power within seconds; reaching the end of this wait means that it did not. */
    for (waited = 0; waited < SLEEP_POWER_OFF_WAIT_MS; waited += 1000u)
        sys_wait(-1, -1, 0, 1000);
    logmsg("the camera is still running after the standby request");
    sleep_retry_ms = sys_now_ms() + SLEEP_RETRY_MS;
    last_activity_ms = sys_now_ms();
    link_fail("standby did not switch the camera off");
}
