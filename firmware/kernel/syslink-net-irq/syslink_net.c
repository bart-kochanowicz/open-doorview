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
        if (dedup_cache[index].hash == hash &&
            dedup_cache[index].length == length &&
            time_before(jiffies, dedup_cache[index].seen +
                        msecs_to_jiffies(RX_DEDUP_WINDOW_MS)))
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

    err = request_irq(irq, doorview_rx_irq, IRQF_TRIGGER_RISING,
                      "doorview-rx", &rx_gpio);
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

    if (hex2bin(credentials, value, sizeof(credentials)) ||
        !credentials[0] || !credentials[STATION_FIELD_SIZE] ||
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
    static const u8 header[40] = { [0] = 0x31, [16] = 0x01,
        [20] = 0x03, [21] = 0xb0, [22] = 0xa0, [23] = 0x20,
        [32] = 0x9a, [34] = 0x01, [35] = 0x01 };
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

static netdev_tx_t doorview_xmit(struct sk_buff *skb, struct net_device *dev)
{
    __be16 ethertype;
    unsigned int filter = READ_ONCE(tx_filter);
    if (skb_copy_bits(skb, 12, &ethertype, sizeof(ethertype)) ||
        READ_ONCE(suppress_tx) || (filter == 1 && ethertype != htons(ETH_P_ARP)) ||
        (filter == 2 && ethertype != htons(ETH_P_ARP) && ethertype != htons(ETH_P_IP)) ||
        skb->len > READ_ONCE(tx_max_len) || skb_queue_len(&outgoing) >= 256) {
        dev->stats.tx_dropped++; dev_kfree_skb(skb); return NETDEV_TX_OK;
    }
    skb_queue_tail(&outgoing, skb);
    wake_up(&worker_wait);
    return NETDEV_TX_OK;
}
static const struct net_device_ops doorview_ops = { .ndo_start_xmit = doorview_xmit, .ndo_set_mac_address = eth_mac_addr, .ndo_validate_addr = eth_validate_addr };
static bool resume_connected;
module_param(resume_connected, bool, 0400);

static int syslink_worker(void *arg)
{
    struct sdio_func *func = arg;
    struct mmc_host *host = func->card->host;
    unsigned int quirks = func->card->quirks;
    unsigned char ctrl, *data;
    unsigned int count = 0;
    unsigned int requested = 0, acknowledged = 0;
    unsigned int empty_reads = 0, transport_frames = 0, ethernet_frames = 0;
    unsigned char connect[24] = {0x21, 0x02};
    unsigned char heartbeat[20] = {0x21, 0x00};
    unsigned int heartbeat_count = 0;
    int err = 0, stage = 0;
    unsigned int read_failures = 0;
    unsigned int rx_passes = 0;
    unsigned int fifo_polls = 0;
    unsigned long next_fifo_poll = jiffies;
    int rx_irq = -ENODEV;
    unsigned long next_heartbeat = jiffies;
    unsigned long next_status = jiffies;
    if (resume_connected) requested = acknowledged = 0x0d;
    data = kmalloc(2048, GFP_KERNEL);
    if (!data) return -ENOMEM;
    sdio_claim_host(func);
    ctrl = sdio_f0_readb(func, SDIO_CCCR_IF, &err);
    if (err) goto out;
    func->card->quirks |= MMC_QUIRK_LENIENT_FN0;
    sdio_f0_writeb(func, ctrl & ~SDIO_BUS_WIDTH_MASK, SDIO_CCCR_IF, &err);
    func->card->quirks = quirks;
    if (err) goto out;
    host->ios.bus_width = MMC_BUS_WIDTH_1;
    pr_info("syslink_sdio: clock before=%u\n", host->ios.clock);
    if (host->ios.clock > 12000000) host->ios.clock = 12000000;
    host->ops->set_ios(host, &host->ios);
    pr_info("syslink_sdio: clock after=%u\n", host->ios.clock);
    err = sdio_enable_func(func);
    if (err) goto out;
    err = sdio_set_block_size(func, 16);
    if (err) goto disable;
    sdio_writel(func, 0x55, 0x24, &err);
    pr_info("syslink_sdio: magic write result=%d\n", err);
    if (err) goto disable;
    memset(connect + 16, 0xa5, 8);
    heartbeat[16] = 0x01; heartbeat[18] = 0x6c; heartbeat[19] = 0x73;
    sdio_release_host(func);
    rx_irq = setup_rx_irq();
    if (rx_gpio >= 0)
        pr_info("doorview: RX GPIO=%d IRQ=%d\n", rx_gpio, rx_irq);
    while (!kthread_should_stop()) {
        unsigned int header, port, mask;
        bool received_ethernet = false;
        bool signal_driven = rx_irq >= 0 && READ_ONCE(irq_rx);
        unsigned long rx_interval = msecs_to_jiffies(
            clamp_t(unsigned int, READ_ONCE(rx_poll_ms), 10, 500));
        sdio_claim_host(func);
        if (!signal_driven || atomic_xchg(&rx_pending, 0) ||
            time_after_eq(jiffies, next_fifo_poll)) {
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
                stage = 2; err = sdio_readsb(func, data, 0, count);
                func->card->cccr.multi_block = multi;
            }
            if (err) { sdio_release_host(func); break; }
            transport_frames++;
            header = data[0] | (data[1] << 8);
            if (header == 0x0004 || header == 0x0804)
                ethernet_frames++;
            received_ethernet = header == 0x0004 || header == 0x0804;
            if (header == 0x0034 && count >= 40 && data[32] == 0x8a) {
                unsigned int length = data[38] | (data[39] << 8);

                pr_info("doorview_control: command=%02x length=%u\n", data[33], length);
                /* Separate prefix: the button listener only matches the line above. */
                if (data[33] != 0xa5 && count > 40) {
                    unsigned int shown = min_t(unsigned int, count - 40, 32);

                    pr_info("doorview_power: command=%02x count=%u length=%u head=%*ph payload=%*ph\n",
                            data[33], count, length, 8, data + 32, (int)shown, data + 40);
                }
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
                        netdev->stats.rx_packets++; netdev->stats.rx_bytes += length;
                        netif_rx_ni(skb);
                    } else netdev->stats.rx_dropped++;
                }
            }
            port = (data[0] >> 4) & 15;
            mask = 1u << port;
            if (count == 24 && (data[0] & 15) == 4 &&
                (data[1] == 2 || data[1] == 3) &&
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
                if (err) { sdio_release_host(func); break; }
            }
        } else if (count) {
            pr_info("syslink_sdio: unsupported packet size=%u\n", count);
            sdio_release_host(func);
            break;
        }
transmit:
        {
            struct sk_buff *skb;
            unsigned int sent = 0;
            while (sent++ < 16 && (skb = skb_dequeue(&outgoing))) {
                unsigned int size = skb->len + 2;
                unsigned int transfer = size > 512 ? ALIGN(size, 16) : size;
                u8 *frame;
                if (size > 512 && (!func->card->cccr.multi_block ||
                    transfer / 16 > host->max_blk_count)) {
                    pr_warn("doorview_tx: cannot send single block request\n");
                    netdev->stats.tx_dropped++; dev_kfree_skb(skb); continue;
                }
                frame = kzalloc(transfer, GFP_KERNEL);
                if (!frame) { netdev->stats.tx_dropped++; dev_kfree_skb(skb); continue; }
                frame[0] = 0x01; frame[1] = 0x00;
                if (skb_copy_bits(skb, 0, frame + 2, skb->len)) err = -EINVAL;
                else {
                    stage = 3; err = sdio_writesb(func, 0, frame, transfer);
                }
                kfree(frame);
                if (err) netdev->stats.tx_errors++;
                else { netdev->stats.tx_packets++; netdev->stats.tx_bytes += skb->len; }
                dev_kfree_skb(skb);
                if (err) break;
            }
            if (err) { sdio_release_host(func); break; }
        }
        if ((acknowledged & (1u << 2)) && time_after_eq(jiffies, next_heartbeat)) {
            stage = 4; err = sdio_writesb(func, 0, heartbeat, sizeof(heartbeat));
            if (err) { pr_info("syslink_sdio: heartbeat failed %d\n", err); sdio_release_host(func); break; }
            next_heartbeat = jiffies + msecs_to_jiffies(500);
            heartbeat_count++;
            if (heartbeat_count == 1 || heartbeat_count % 20 == 0)
                pr_info("syslink_sdio: heartbeats sent=%u\n", heartbeat_count);
        }
        if (acknowledged & (1u << 3)) {
            stage = 5;
            err = send_station_request(func, data);
            if (err) {
                sdio_release_host(func);
                break;
            }
        }
        if (time_after_eq(jiffies, next_status)) {
            pr_info("doorview: FIFO empty=%u frames=%u ethernet=%u tx=%lu errors=%lu polls=%u signals=%u dedup=%u\n",
                    empty_reads, transport_frames, ethernet_frames,
                    netdev->stats.tx_packets, netdev->stats.tx_errors,
                    fifo_polls, atomic_read(&rx_signals), duplicate_frames);
            next_status = jiffies + msecs_to_jiffies(15000);
        }
        sdio_release_host(func);
        /* Continuous Ethernet traffic can drain up to eight reads per wake. */
        if (signal_driven) {
            wait_event_interruptible_timeout(worker_wait,
                kthread_should_stop() || atomic_read(&rx_pending) ||
                !skb_queue_empty(&outgoing), rx_interval);
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
    pr_info("syslink_sdio: stopped err=%d stage=%d requested=%04x acknowledged=%04x heartbeats=%u\n", err, stage, requested, acknowledged, heartbeat_count);
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
    if (IS_ERR(syslink_task)) return PTR_ERR(syslink_task);
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
static const struct sdio_device_id ids[] = { { SDIO_DEVICE(0x0296, 0x5347) }, { } };
MODULE_DEVICE_TABLE(sdio, ids);
static struct sdio_driver driver = { .name="syslink_sdio_probe", .id_table=ids, .probe=syslink_sdio_probe, .remove=syslink_sdio_remove };
static int __init diag_init(void)
{
    int err;
    skb_queue_head_init(&outgoing);
    netdev = alloc_etherdev(0);
    if (!netdev) return -ENOMEM;
    strlcpy(netdev->name, "dv%d", IFNAMSIZ);
    netdev->netdev_ops = &doorview_ops;
    eth_hw_addr_random(netdev);
    err = register_netdev(netdev);
    if (err) { free_netdev(netdev); return err; }
    err = sdio_register_driver(&driver);
    if (err) { unregister_netdev(netdev); free_netdev(netdev); }
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
