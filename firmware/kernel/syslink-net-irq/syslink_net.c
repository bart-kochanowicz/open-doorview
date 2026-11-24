#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/gpio.h>
#include <linux/interrupt.h>
#include <linux/wait.h>
#include <linux/kthread.h>
#include <linux/jiffies.h>
#include <linux/mmc/card.h>
#include <linux/mmc/host.h>
#include <linux/mmc/sdio.h>
#include <linux/mmc/sdio_func.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/printk.h>
#include <linux/slab.h>
#include <linux/etherdevice.h>
#include <linux/netdevice.h>
#include <linux/skbuff.h>

static struct task_struct *syslink_task;
static struct net_device *netdev;
static bool suppress_tx;
static bool rx_burst;
module_param(rx_burst, bool, 0600);
static unsigned int tx_filter = 2;
static unsigned int tx_max_len = 500;
module_param(suppress_tx, bool, 0600);
module_param(tx_filter, uint, 0600);
module_param(tx_max_len, uint, 0600);
static struct sk_buff_head outgoing;
static int rx_gpio = -1;
module_param(rx_gpio, int, 0400);
static bool irq_rx = true;
module_param(irq_rx, bool, 0600);
static unsigned int rx_poll_ms = 30;
module_param(rx_poll_ms, uint, 0600);
/* Drop an Ethernet frame identical to the previously delivered one. */
static bool rx_dedup = true;
module_param(rx_dedup, bool, 0600);
static unsigned int duplicate_frames;
static DECLARE_WAIT_QUEUE_HEAD(worker_wait);
static atomic_t rx_pending = ATOMIC_INIT(0);
static atomic_t rx_signals = ATOMIC_INIT(0);

static irqreturn_t doorview_rx_irq(int irq, void *context)
{
    atomic_inc(&rx_signals);
    atomic_set(&rx_pending, 1);
    wake_up(&worker_wait);
    return IRQ_HANDLED;
}

static u32 frame_hash(const u8 *data, unsigned int length)
{
    u32 hash = 2166136261u;

    while (length--) {
        hash ^= *data++;
        hash *= 16777619u;
    }
    return hash;
}

#define RX_DEDUP_SLOTS 8
#define RX_DEDUP_WINDOW_MS 2000
struct rx_dedup_entry {
    u32 hash;
    unsigned int length;
    unsigned long seen;
};
static struct rx_dedup_entry dedup_cache[RX_DEDUP_SLOTS];
static unsigned int dedup_next;

/* Frames are re-served by the companion and arrive interleaved with others. */
static bool frame_is_duplicate(const u8 *data, unsigned int length)
{
    u32 hash = frame_hash(data, length);
    unsigned int index;

    for (index = 0; index < RX_DEDUP_SLOTS; index++) {
        if (dedup_cache[index].hash == hash && dedup_cache[index].length == length &&
            time_before(jiffies, dedup_cache[index].seen + msecs_to_jiffies(RX_DEDUP_WINDOW_MS)))
            return true;
    }

    dedup_cache[dedup_next].hash = hash;
    dedup_cache[dedup_next].length = length;
    dedup_cache[dedup_next].seen = jiffies;
    dedup_next = (dedup_next + 1) % RX_DEDUP_SLOTS;
    return false;
}

static int setup_rx_irq(void)
{
    int irq, err;

    if (rx_gpio < 0)
        return -ENODEV;

    err = gpio_request_one(rx_gpio, GPIOF_IN, "doorview-rx");
    if (err)
        return err;

    irq = gpio_to_irq(rx_gpio);
    if (irq < 0) {
        err = irq;
        goto release_gpio;
    }

    err = request_irq(irq, doorview_rx_irq, IRQF_TRIGGER_RISING, "doorview-rx", &rx_gpio);
    if (err)
        goto release_gpio;

    return irq;

release_gpio:
    gpio_free(rx_gpio);
    return err;
}

#define STATION_FIELD_SIZE 32
#define STATION_DATA_SIZE (2 * STATION_FIELD_SIZE)
#define STATION_SETUP_DELAY_MS 12000
#define STATION_STOP_DELAY_MS 3500

static DEFINE_MUTEX(station_lock);
static u8 station_data[STATION_DATA_SIZE];
enum station_step {
    STATION_IDLE,
    STATION_STOP,
    STATION_START,
    STATION_CONNECT,
};
static enum station_step station_step;
static unsigned long station_after;
static bool restart_requested = true;

static int station_set(const char *value, const struct kernel_param *param)
{
    u8 credentials[STATION_DATA_SIZE];
    size_t len = strlen(value);
    int err = 0;

    if (len && value[len - 1] == '\n')
        len--;
    if (len != sizeof(credentials) * 2)
        return -EINVAL;

    if (hex2bin(credentials, value, sizeof(credentials)) || !credentials[0] || !credentials[STATION_FIELD_SIZE] ||
        credentials[STATION_FIELD_SIZE - 1] || credentials[STATION_DATA_SIZE - 1]) {
        err = -EINVAL;
        goto clear;
    }

    mutex_lock(&station_lock);
    if (station_step != STATION_IDLE) {
        err = -EBUSY;
    } else {
        memcpy(station_data, credentials, sizeof(station_data));
        station_step = param->arg ? STATION_STOP : STATION_START;
        station_after = jiffies;
    }
    mutex_unlock(&station_lock);

clear:
    memzero_explicit(credentials, sizeof(credentials));
    return err;
}

static const struct kernel_param_ops station_ops = { .set = station_set };
module_param_cb(station, &station_ops, NULL, 0200);

module_param_cb(reconnect, &station_ops, &restart_requested, 0200);

/* Keep polling and sending heartbeats during the radio transitions. */
static int send_station_request(struct sdio_func *func, u8 *data)
{
    static const u8 header[40] = { [0] = 0x31,  [16] = 0x01, [20] = 0x03, [21] = 0xb0, [22] = 0xa0,
                                   [23] = 0x20, [32] = 0x9a, [34] = 0x01, [35] = 0x01 };
    size_t length = sizeof(header);
    int err = 0;

    mutex_lock(&station_lock);
    if (station_step == STATION_IDLE || time_before(jiffies, station_after))
        goto unlock;

    memcpy(data, header, sizeof(header));
    data[28] = data[38] = 0x08;
    switch (station_step) {
    case STATION_STOP:
        data[33] = 0x23;
        break;
    case STATION_START:
        data[33] = 0x22;
        break;
    case STATION_CONNECT:
        data[28] = data[38] = 0x48;
        data[33] = 0x24;
        memcpy(data + sizeof(header), station_data, sizeof(station_data));
        length += sizeof(station_data);
        break;
    case STATION_IDLE:
        goto unlock;
    }

    err = sdio_writesb(func, 0, data, length);
    if (length > sizeof(header))
        memzero_explicit(data + sizeof(header), sizeof(station_data));
    if (!err)
        pr_info("doorview: station command=%02x sent\n", data[33]);

    if (!err && station_step == STATION_STOP) {
        station_step = STATION_START;
        station_after = jiffies + msecs_to_jiffies(STATION_STOP_DELAY_MS);
    } else if (!err && station_step == STATION_START) {
        station_step = STATION_CONNECT;
        station_after = jiffies + msecs_to_jiffies(STATION_SETUP_DELAY_MS);
    } else {
        station_step = STATION_IDLE;
        memzero_explicit(station_data, sizeof(station_data));
    }

unlock:
    mutex_unlock(&station_lock);
    return err;
}

/*
 * One command for the coprocessor on the application channel (0x8a), written as hex digits: the command byte and its
 * payload. Only these are accepted; every other command stays refused until it has been tested on its own:
 *   0x78  PIR off/on, u16 (0 or 1)                                  "780000", "780100"
 *   0x79  PIR sensitivity, level 1 to 5 in the high byte of a u16   "790001" (the factory app sends 1, 3 or 5)
 *   0x7b  wake-up timer, u32 seconds little endian, 0 = off, at most a week   "7b00000000", "7b2c010000" (300 s)
 */
#define MCU_PAYLOAD_MAX 4
#define MCU_TIMER_MAX 604800u

static DEFINE_MUTEX(mcu_lock);
static u8 mcu_command;
static u8 mcu_payload[MCU_PAYLOAD_MAX];
static unsigned int mcu_payload_size;
static bool mcu_pending;

static int mcu_set(const char *value, const struct kernel_param *param)
{
    u8 raw[1 + MCU_PAYLOAD_MAX];
    unsigned int size;
    size_t len = strlen(value);
    int err = 0;

    if (len && value[len - 1] == '\n')
        len--;
    if (len == 6)
        size = 2;
    else if (len == 10)
        size = 4;
    else
        return -EINVAL;
    if (hex2bin(raw, value, 1 + size))
        return -EINVAL;
    if (raw[0] == 0x78 && size == 2) {
        if (raw[1] > 1 || raw[2])
            return -EINVAL;
    } else if (raw[0] == 0x79 && size == 2) {
        if (raw[1] || raw[2] < 1 || raw[2] > 5)
            return -EINVAL;
    } else if (raw[0] == 0x7b && size == 4) {
        u32 seconds = raw[1] | (raw[2] << 8) | (raw[3] << 16) | ((u32)raw[4] << 24);

        if (seconds > MCU_TIMER_MAX)
            return -EINVAL;
    } else if (raw[0] == 0x78 || raw[0] == 0x79 || raw[0] == 0x7b) {
        return -EINVAL;
    } else {
        return -EPERM;
    }

    mutex_lock(&mcu_lock);
    if (mcu_pending) {
        err = -EBUSY;
    } else {
        mcu_command = raw[0];
        memcpy(mcu_payload, raw + 1, size);
        mcu_payload_size = size;
        mcu_pending = true;
    }
    mutex_unlock(&mcu_lock);
    return err;
}

static const struct kernel_param_ops mcu_ops = { .set = mcu_set };
module_param_cb(mcu, &mcu_ops, NULL, 0200);

static int send_mcu_request(struct sdio_func *func, u8 *data)
{
    static const u8 header[40] = { [0] = 0x31,  [16] = 0x01, [20] = 0x02, [21] = 0xb0, [22] = 0xa0,
                                   [23] = 0x20, [32] = 0x8a, [34] = 0x01, [35] = 0x01 };
    u8 command, payload[MCU_PAYLOAD_MAX];
    unsigned int size;
    int err;

    mutex_lock(&mcu_lock);
    if (!mcu_pending) {
        mutex_unlock(&mcu_lock);
        return 0;
    }
    command = mcu_command;
    size = mcu_payload_size;
    memcpy(payload, mcu_payload, size);
    mutex_unlock(&mcu_lock);

    memcpy(data, header, sizeof(header));
    data[28] = data[38] = 8 + size;
    data[33] = command;
    memcpy(data + sizeof(header), payload, size);
    err = sdio_writesb(func, 0, data, sizeof(header) + size);
    if (!err)
        pr_info("doorview: mcu command=%02x payload=%*phN sent\n", command, (int)size, payload);

    /* A failed write is not repeated: the owner asked once and reads the log. */
    mutex_lock(&mcu_lock);
    mcu_pending = false;
    mutex_unlock(&mcu_lock);
    return err;
}

/*
 * One keep-alive command for the coprocessor's Wi-Fi part (0x9a), written as hex digits: the command byte and its
 * payload. This is what the factory firmware sends before a standby so that a server can wake the camera
 * (docs/remote-wake.md). Only these are accepted, each checked field by field:
 *   0x04  stop the keep-alive, no payload                             "04"
 *   0x05  start the keep-alive, no payload                            "05"
 *   0x07  authentication: written as "07" alone, sent as 304 zero bytes (none; the factory's types 1 to 3 need a
 *         vendor server)
 *   0x2c  wake-up pattern, 261 bytes: on/off, then four entries of 64 pattern bytes and a length (at most 64)
 *   0x30  keep-alive servers, 293 bytes: on/off, number of servers (1 to 4), wake line threshold, interval u16 LE,
 *         then four entries of 72 bytes: enabled, packet length (at most 64), port u16 LE, IPv4, 64 packet bytes
 */
#define WIFI_PAYLOAD_MAX 304
#define WIFI_AUTH_SIZE 304
#define WIFI_PATTERN_SIZE 261
#define WIFI_SERVERS_SIZE 293

static DEFINE_MUTEX(wifi_lock);
static u8 wifi_command;
static u8 wifi_payload[WIFI_PAYLOAD_MAX];
static unsigned int wifi_payload_size;
static bool wifi_pending;

static bool wifi_pattern_valid(const u8 *p)
{
    unsigned int i;

    if (p[0] > 1)
        return false;
    for (i = 0; i < 4; i++)
        if (p[1 + i * 65 + 64] > 64)
            return false;
    return true;
}

static bool wifi_servers_valid(const u8 *p)
{
    unsigned int i;

    if (p[0] > 1 || p[1] < 1 || p[1] > 4 || p[2] < 1 || p[2] > p[1])
        return false;
    for (i = 0; i < 4; i++) {
        const u8 *server = p + 5 + i * 72;

        if (server[0] > 1 || server[1] > 64 || (i >= p[1] && server[0]))
            return false;
    }
    return true;
}

static int wifi_set(const char *value, const struct kernel_param *param)
{
    u8 *raw;
    unsigned int size;
    size_t len = strlen(value);
    int err = 0;

    if (len && value[len - 1] == '\n')
        len--;
    if (len < 2 || len % 2 || len > 2 * (1 + WIFI_SERVERS_SIZE))
        return -EINVAL;
    size = len / 2 - 1;
    raw = kzalloc(1 + WIFI_PAYLOAD_MAX, GFP_KERNEL);
    if (!raw)
        return -ENOMEM;
    if (hex2bin(raw, value, 1 + size)) {
        err = -EINVAL;
        goto out;
    }
    switch (raw[0]) {
    case 0x04:
    case 0x05:
        if (size)
            err = -EINVAL;
        break;
    case 0x07:
        if (size)
            err = -EINVAL;
        size = WIFI_AUTH_SIZE;
        break;
    case 0x2c:
        if (size != WIFI_PATTERN_SIZE || !wifi_pattern_valid(raw + 1))
            err = -EINVAL;
        break;
    case 0x30:
        if (size != WIFI_SERVERS_SIZE || !wifi_servers_valid(raw + 1))
            err = -EINVAL;
        break;
    default:
        err = -EPERM;
    }
    if (err)
        goto out;

    mutex_lock(&wifi_lock);
    if (wifi_pending) {
        err = -EBUSY;
    } else {
        wifi_command = raw[0];
        memcpy(wifi_payload, raw + 1, size);
        wifi_payload_size = size;
        wifi_pending = true;
    }
    mutex_unlock(&wifi_lock);
out:
    kfree(raw);
    return err;
}

static const struct kernel_param_ops wifi_ops = { .set = wifi_set };
module_param_cb(wifi, &wifi_ops, NULL, 0200);

static int send_wifi_request(struct sdio_func *func, u8 *data)
{
    static const u8 header[40] = { [0] = 0x31,  [16] = 0x01, [20] = 0x03, [21] = 0xb0, [22] = 0xa0,
                                   [23] = 0x20, [32] = 0x9a, [34] = 0x01, [35] = 0x01 };
    unsigned int size, length;
    int err;

    mutex_lock(&wifi_lock);
    if (!wifi_pending) {
        mutex_unlock(&wifi_lock);
        return 0;
    }
    size = wifi_payload_size;
    memcpy(data, header, sizeof(header));
    /* Bytes 28 and 38 start two little-endian u16 lengths (the factory's syslink framing). */
    length = 8 + size;
    data[28] = data[38] = length & 0xff;
    data[29] = data[39] = length >> 8;
    data[33] = wifi_command;
    memcpy(data + sizeof(header), wifi_payload, size);
    wifi_pending = false;
    mutex_unlock(&wifi_lock);

    err = sdio_writesb(func, 0, data, sizeof(header) + size);
    if (!err)
        pr_info("doorview: wifi command=%02x length=%u sent\n", data[33], size);
    /* A failed write is not repeated, as for the mcu parameter. */
    return err;
}

/*
 * The factory standby, step by step (docs/factory-firmware.md): 8a:77 07, then 9a:03,
 * then the answer 8a:61 01 00 00 00 when the coprocessor asks with 0xa0. Writing 1 to
 * "standby" starts it once; the coprocessor then switches the SoC off, so sync first.
 */
#define STANDBY_STATE_DELAY_MS 200
#define STANDBY_ASK_WAIT_MS 15000

enum standby_step {
    STANDBY_IDLE,
    STANDBY_STATE,
    STANDBY_NOTICE,
    STANDBY_WAIT,
    STANDBY_ANSWER,
};
static DEFINE_MUTEX(standby_lock);
static enum standby_step standby_step;
static unsigned long standby_after;

static int standby_set(const char *value, const struct kernel_param *param)
{
    int err = 0;

    if (strcmp(value, "1") && strcmp(value, "1\n"))
        return -EINVAL;
    mutex_lock(&standby_lock);
    if (standby_step != STANDBY_IDLE) {
        err = -EBUSY;
    } else {
        standby_step = STANDBY_STATE;
        standby_after = jiffies;
    }
    mutex_unlock(&standby_lock);
    return err;
}

static const struct kernel_param_ops standby_ops = { .set = standby_set };
module_param_cb(standby, &standby_ops, NULL, 0200);

/* Called for every message that the coprocessor sends on the application channel. */
static void standby_saw(u8 command)
{
    mutex_lock(&standby_lock);
    if (command == 0xa0 && standby_step == STANDBY_WAIT)
        standby_step = STANDBY_ANSWER;
    mutex_unlock(&standby_lock);
}

static int send_standby_request(struct sdio_func *func, u8 *data)
{
    static const u8 app[40] = { [0] = 0x31,  [16] = 0x01, [20] = 0x02, [21] = 0xb0, [22] = 0xa0,
                                [23] = 0x20, [32] = 0x8a, [34] = 0x01, [35] = 0x01 };
    static const u8 wifi[40] = { [0] = 0x31,  [16] = 0x01, [20] = 0x03, [21] = 0xb0, [22] = 0xa0,
                                 [23] = 0x20, [32] = 0x9a, [34] = 0x01, [35] = 0x01 };
    size_t length = 0;
    int err = 0;

    mutex_lock(&standby_lock);
    if (standby_step == STANDBY_IDLE)
        goto unlock;
    if (standby_step == STANDBY_WAIT) {
        if (time_after_eq(jiffies, standby_after)) {
            pr_warn("doorview: standby: the coprocessor did not ask (0xa0), giving up\n");
            standby_step = STANDBY_IDLE;
        }
        goto unlock;
    }
    /* The answer is sent at once: the coprocessor waits only a few seconds for it. */
    if (standby_step != STANDBY_ANSWER && time_before(jiffies, standby_after))
        goto unlock;
    switch (standby_step) {
    case STANDBY_STATE:
        memcpy(data, app, sizeof(app));
        data[28] = data[38] = 0x09;
        data[33] = 0x77;
        data[40] = 0x07;
        length = sizeof(app) + 1;
        break;
    case STANDBY_NOTICE:
        memcpy(data, wifi, sizeof(wifi));
        data[28] = data[38] = 0x08;
        data[33] = 0x03;
        length = sizeof(wifi);
        break;
    case STANDBY_ANSWER:
        memcpy(data, app, sizeof(app));
        data[28] = data[38] = 0x0c;
        data[33] = 0x61;
        data[40] = 0x01;
        length = sizeof(app) + 4;
        break;
    default:
        goto unlock;
    }
    err = sdio_writesb(func, 0, data, length);
    if (err) {
        standby_step = STANDBY_IDLE;
        goto unlock;
    }
    pr_info("doorview: standby: %c%c:%02x sent\n", data[32] >> 4 == 8 ? '8' : '9', 'a', data[33]);
    if (standby_step == STANDBY_STATE) {
        standby_step = STANDBY_NOTICE;
        standby_after = jiffies + msecs_to_jiffies(STANDBY_STATE_DELAY_MS);
    } else if (standby_step == STANDBY_NOTICE) {
        standby_step = STANDBY_WAIT;
        standby_after = jiffies + msecs_to_jiffies(STANDBY_ASK_WAIT_MS);
    } else {
        standby_step = STANDBY_IDLE;
    }

unlock:
    mutex_unlock(&standby_lock);
    return err;
}

static netdev_tx_t doorview_xmit(struct sk_buff *skb, struct net_device *dev)
{
    __be16 ethertype;
    unsigned int filter = READ_ONCE(tx_filter);
    if (skb_copy_bits(skb, 12, &ethertype, sizeof(ethertype)) || READ_ONCE(suppress_tx) ||
        (filter == 1 && ethertype != htons(ETH_P_ARP)) ||
        (filter == 2 && ethertype != htons(ETH_P_ARP) && ethertype != htons(ETH_P_IP)) ||
        skb->len > READ_ONCE(tx_max_len) || skb_queue_len(&outgoing) >= 256) {
        dev->stats.tx_dropped++;
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }
    skb_queue_tail(&outgoing, skb);
    wake_up(&worker_wait);
    return NETDEV_TX_OK;
}
static const struct net_device_ops doorview_ops = { .ndo_start_xmit = doorview_xmit,
                                                    .ndo_set_mac_address = eth_mac_addr,
                                                    .ndo_validate_addr = eth_validate_addr };
static bool resume_connected;
module_param(resume_connected, bool, 0400);
/* Logs every frame that is neither Ethernet nor an application message, for tracing the coprocessor. */
static bool log_frames;
module_param(log_frames, bool, 0600);

/* The SDIO function setup is tried this often, this far apart (see syslink_worker). */
#define INIT_ATTEMPTS 15
#define INIT_RETRY_MS 200

static int syslink_worker(void *arg)
{
    unsigned int attempt;
    struct sdio_func *func = arg;
    struct mmc_host *host = func->card->host;
    unsigned int quirks = func->card->quirks;
    unsigned char ctrl, *data;
    unsigned int count = 0;
    unsigned int requested = 0, acknowledged = 0;
    unsigned int empty_reads = 0, transport_frames = 0, ethernet_frames = 0;
    unsigned char connect[24] = { 0x21, 0x02 };
    unsigned char heartbeat[20] = { 0x21, 0x00 };
    unsigned int heartbeat_count = 0;
    int err = 0, stage = 0;
    unsigned int read_failures = 0;
    unsigned int rx_passes = 0;
    unsigned int fifo_polls = 0;
    unsigned long next_fifo_poll = jiffies;
    int rx_irq = -ENODEV;
    unsigned long next_heartbeat = jiffies;
    unsigned long next_status = jiffies;
    if (resume_connected)
        requested = acknowledged = 0x0d;
    data = kmalloc(2048, GFP_KERNEL);
    if (!data)
        return -ENOMEM;
    sdio_claim_host(func);
    ctrl = sdio_f0_readb(func, SDIO_CCCR_IF, &err);
    if (err)
        goto out;
    func->card->quirks |= MMC_QUIRK_LENIENT_FN0;
    sdio_f0_writeb(func, ctrl & ~SDIO_BUS_WIDTH_MASK, SDIO_CCCR_IF, &err);
    func->card->quirks = quirks;
    if (err)
        goto out;
    host->ios.bus_width = MMC_BUS_WIDTH_1;
    pr_info("syslink_sdio: clock before=%u\n", host->ios.clock);
    if (host->ios.clock > 12000000)
        host->ios.clock = 12000000;
    host->ops->set_ios(host, &host->ios);
    pr_info("syslink_sdio: clock after=%u\n", host->ios.clock);
    /*
     * After a wake-up from the network the coprocessor is still closing its keep-alive when this runs, and the function
     * can stay not ready for a while (observed 2026-11-24: the first attempt failed in more than half of those boots,
     * one about 2 s later worked). Without heartbeats the coprocessor resets the SoC after about 10 s, so try again
     * at short intervals instead of giving up.
     */
    for (attempt = 1;; attempt++) {
        err = sdio_enable_func(func);
        if (!err)
            err = sdio_set_block_size(func, 16);
        if (!err)
            sdio_writel(func, 0x55, 0x24, &err);
        if (!err || attempt == INIT_ATTEMPTS)
            break;
        pr_warn("syslink_sdio: init attempt %u failed err=%d\n", attempt, err);
        sdio_release_host(func);
        msleep(INIT_RETRY_MS);
        sdio_claim_host(func);
    }
    pr_info("syslink_sdio: magic write result=%d attempt=%u\n", err, attempt);
    if (err)
        goto disable;
    memset(connect + 16, 0xa5, 8);
    heartbeat[16] = 0x01;
    heartbeat[18] = 0x6c;
    heartbeat[19] = 0x73;
    sdio_release_host(func);
    rx_irq = setup_rx_irq();
    if (rx_gpio >= 0)
        pr_info("doorview: RX GPIO=%d IRQ=%d\n", rx_gpio, rx_irq);
    while (!kthread_should_stop()) {
        unsigned int header, port, mask;
        bool received_ethernet = false;
        bool signal_driven = rx_irq >= 0 && READ_ONCE(irq_rx);
        unsigned long rx_interval = msecs_to_jiffies(clamp_t(unsigned int, READ_ONCE(rx_poll_ms), 10, 500));
        sdio_claim_host(func);
        if (!signal_driven || atomic_xchg(&rx_pending, 0) || time_after_eq(jiffies, next_fifo_poll)) {
            stage = 1;
            count = sdio_readl(func, 0x0c, &err);
            next_fifo_poll = jiffies + rx_interval;
            fifo_polls++;
        } else {
            count = 0;
            goto transmit;
        }
        if (err) {
            int heartbeat_err = 0;
            ++read_failures;
            if (read_failures <= 8) {
                if (acknowledged & (1u << 2))
                    heartbeat_err = sdio_writesb(func, 0, heartbeat, sizeof(heartbeat));
                pr_warn("syslink_sdio: read err=%d retry=%u heartbeat_err=%d\n", err, read_failures, heartbeat_err);
                sdio_release_host(func);
                msleep(50);
                continue;
            }
            sdio_release_host(func);
            break;
        }
        read_failures = 0;
        if (!count)
            empty_reads++;
        if (count >= 2 && count <= 2048) {
            {
                unsigned int multi = func->card->cccr.multi_block;
                func->card->cccr.multi_block = 0;
                stage = 2;
                err = sdio_readsb(func, data, 0, count);
                func->card->cccr.multi_block = multi;
            }
            if (err) {
                sdio_release_host(func);
                break;
            }
            transport_frames++;
            header = data[0] | (data[1] << 8);
            if (header == 0x0004 || header == 0x0804)
                ethernet_frames++;
            received_ethernet = header == 0x0004 || header == 0x0804;
            if (log_frames && !received_ethernet && !(header == 0x0034 && count >= 40 && data[32] == 0x8a))
                pr_info_ratelimited("doorview_frame: header=%04x count=%u data=%*ph\n", header, count,
                                    (int)min_t(unsigned int, count, 48), data);
            if (header == 0x0034 && count >= 40 && data[32] == 0x8a) {
                unsigned int length = data[38] | (data[39] << 8);

                pr_info("doorview_control: command=%02x length=%u\n", data[33], length);
                standby_saw(data[33]);
                /* Separate prefix: the button listener only matches the line above. */
                if (data[33] != 0xa5 && count > 40) {
                    unsigned int shown = min_t(unsigned int, count - 40, 32);

                    pr_info("doorview_power: command=%02x count=%u length=%u head=%*ph payload=%*ph\n", data[33], count,
                            length, 8, data + 32, (int)shown, data + 40);
                }
            }
            if (header == 0x0034 && count >= 40 && data[32] == 0x9a) {
                unsigned int shown = min_t(unsigned int, count - 40, 32);

                pr_info("doorview_wifi: command=%02x count=%u length=%u payload=%*ph\n", data[33], count,
                        data[38] | (data[39] << 8), (int)shown, data + 40);
            }
            if ((header == 0x0004 || header == 0x0804) && count >= 16 && netif_running(netdev)) {
                unsigned int length = count - 2;

                if (rx_dedup && frame_is_duplicate(data + 2, length)) {
                    duplicate_frames++;
                    received_ethernet = false;
                } else {
                    struct sk_buff *skb = netdev_alloc_skb_ip_align(netdev, length);
                    if (skb) {
                        memcpy(skb_put(skb, length), data + 2, length);
                        skb->protocol = eth_type_trans(skb, netdev);
                        netdev->stats.rx_packets++;
                        netdev->stats.rx_bytes += length;
                        netif_rx_ni(skb);
                    } else
                        netdev->stats.rx_dropped++;
                }
            }
            port = (data[0] >> 4) & 15;
            mask = 1u << port;
            if (count == 24 && (data[0] & 15) == 4 && (data[1] == 2 || data[1] == 3) &&
                !memcmp(data + 16, "\xa5\xa5\xa5\xa5\xa5\xa5\xa5\xa5", 8)) {
                connect[0] = (data[0] & 0xf0) | 1;
                if (data[1] == 2 && !(requested & mask)) {
                    connect[1] = 2;
                    err = sdio_writesb(func, 0, connect, sizeof(connect));
                    pr_info("syslink_sdio: port=%u request result=%d\n", port, err);
                    requested |= mask;
                } else if (data[1] == 3 && (requested & mask) && !(acknowledged & mask)) {
                    connect[1] = 3;
                    err = sdio_writesb(func, 0, connect, sizeof(connect));
                    pr_info("syslink_sdio: port=%u confirmed, ack result=%d\n", port, err);
                    acknowledged |= mask;
                }
                if (err) {
                    sdio_release_host(func);
                    break;
                }
            }
        } else if (count) {
            pr_info("syslink_sdio: unsupported packet size=%u\n", count);
            sdio_release_host(func);
            break;
        }
    transmit : {
        struct sk_buff *skb;
        unsigned int sent = 0;
        while (sent++ < 16 && (skb = skb_dequeue(&outgoing))) {
            unsigned int size = skb->len + 2;
            unsigned int transfer = size > 512 ? ALIGN(size, 16) : size;
            u8 *frame;
            if (size > 512 && (!func->card->cccr.multi_block || transfer / 16 > host->max_blk_count)) {
                pr_warn("doorview_tx: cannot send single block request\n");
                netdev->stats.tx_dropped++;
                dev_kfree_skb(skb);
                continue;
            }
            frame = kzalloc(transfer, GFP_KERNEL);
            if (!frame) {
                netdev->stats.tx_dropped++;
                dev_kfree_skb(skb);
                continue;
            }
            frame[0] = 0x01;
            frame[1] = 0x00;
            if (skb_copy_bits(skb, 0, frame + 2, skb->len))
                err = -EINVAL;
            else {
                stage = 3;
                err = sdio_writesb(func, 0, frame, transfer);
            }
            kfree(frame);
            if (err)
                netdev->stats.tx_errors++;
            else {
                netdev->stats.tx_packets++;
                netdev->stats.tx_bytes += skb->len;
            }
            dev_kfree_skb(skb);
            if (err)
                break;
        }
        if (err) {
            sdio_release_host(func);
            break;
        }
    }
        if ((acknowledged & (1u << 2)) && time_after_eq(jiffies, next_heartbeat)) {
            stage = 4;
            err = sdio_writesb(func, 0, heartbeat, sizeof(heartbeat));
            if (err) {
                pr_info("syslink_sdio: heartbeat failed %d\n", err);
                sdio_release_host(func);
                break;
            }
            next_heartbeat = jiffies + msecs_to_jiffies(500);
            heartbeat_count++;
            if (heartbeat_count == 1 || heartbeat_count % 20 == 0)
                pr_info("syslink_sdio: heartbeats sent=%u\n", heartbeat_count);
        }
        if (acknowledged & (1u << 3)) {
            stage = 5;
            err = send_station_request(func, data);
            if (!err)
                err = send_mcu_request(func, data);
            if (!err)
                err = send_wifi_request(func, data);
            if (!err)
                err = send_standby_request(func, data);
            if (err) {
                sdio_release_host(func);
                break;
            }
        }
        if (time_after_eq(jiffies, next_status)) {
            pr_info("doorview: FIFO empty=%u frames=%u ethernet=%u tx=%lu errors=%lu polls=%u signals=%u dedup=%u\n",
                    empty_reads, transport_frames, ethernet_frames, netdev->stats.tx_packets, netdev->stats.tx_errors,
                    fifo_polls, atomic_read(&rx_signals), duplicate_frames);
            next_status = jiffies + msecs_to_jiffies(15000);
        }
        sdio_release_host(func);
        /* Continuous Ethernet traffic can drain up to eight reads per wake. */
        if (signal_driven) {
            wait_event_interruptible_timeout(
                worker_wait, kthread_should_stop() || atomic_read(&rx_pending) || !skb_queue_empty(&outgoing),
                rx_interval);
            continue;
        }
        if (READ_ONCE(rx_burst) && received_ethernet && ++rx_passes < 8) {
            cond_resched();
            continue;
        }
        rx_passes = 0;
        usleep_range(2000, 3000);
    }
    if (rx_irq >= 0) {
        free_irq(rx_irq, &rx_gpio);
        gpio_free(rx_gpio);
    }
    pr_info("syslink_sdio: stopped err=%d stage=%d requested=%04x acknowledged=%04x heartbeats=%u\n", err, stage,
            requested, acknowledged, heartbeat_count);
    sdio_claim_host(func);

disable:
    sdio_disable_func(func);
out:
    sdio_release_host(func);
    mutex_lock(&station_lock);
    station_step = STATION_IDLE;
    memzero_explicit(station_data, sizeof(station_data));
    mutex_unlock(&station_lock);
    kfree(data);
    return err;
}
static int syslink_sdio_probe(struct sdio_func *func, const struct sdio_device_id *id)
{
    (void)id;
    syslink_task = kthread_create(syslink_worker, func, "syslink_worker");
    if (IS_ERR(syslink_task))
        return PTR_ERR(syslink_task);
    get_task_struct(syslink_task);
    wake_up_process(syslink_task);
    return 0;
}
static void syslink_sdio_remove(struct sdio_func *func)
{
    (void)func;
    if (!IS_ERR_OR_NULL(syslink_task)) {
        kthread_stop(syslink_task);
        put_task_struct(syslink_task);
    }
    syslink_task = NULL;
}
static const struct sdio_device_id ids[] = { { SDIO_DEVICE(0x0296, 0x5347) }, {} };
MODULE_DEVICE_TABLE(sdio, ids);
static struct sdio_driver driver = {
    .name = "syslink_sdio_probe", .id_table = ids, .probe = syslink_sdio_probe, .remove = syslink_sdio_remove
};
static int __init diag_init(void)
{
    int err;
    skb_queue_head_init(&outgoing);
    netdev = alloc_etherdev(0);
    if (!netdev)
        return -ENOMEM;
    strlcpy(netdev->name, "dv%d", IFNAMSIZ);
    netdev->netdev_ops = &doorview_ops;
    eth_hw_addr_random(netdev);
    err = register_netdev(netdev);
    if (err) {
        free_netdev(netdev);
        return err;
    }
    err = sdio_register_driver(&driver);
    if (err) {
        unregister_netdev(netdev);
        free_netdev(netdev);
    }
    return err;
}
static void __exit diag_exit(void)
{
    sdio_unregister_driver(&driver);
    memzero_explicit(station_data, sizeof(station_data));
    unregister_netdev(netdev);
    skb_queue_purge(&outgoing);
    free_netdev(netdev);
}
module_init(diag_init);
module_exit(diag_exit);
MODULE_LICENSE("GPL");
