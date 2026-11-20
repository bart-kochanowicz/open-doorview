#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/kthread.h>
#include <linux/jiffies.h>
#include <linux/mmc/card.h>
#include <linux/mmc/host.h>
#include <linux/mmc/sdio.h>
#include <linux/mmc/sdio_func.h>
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/slab.h>

static struct task_struct *syslink_task;
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
    unsigned int last_header = 0xffff;
    unsigned char connect[24] = {0x21, 0x02};
    unsigned char heartbeat[20] = {0x21, 0x00};
    unsigned int heartbeat_count = 0;
    int err = 0;
    unsigned long next_heartbeat = jiffies;
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
    host->ops->set_ios(host, &host->ios);
    err = sdio_enable_func(func);
    if (err) goto out;
    err = sdio_set_block_size(func, 512);
    if (err) goto disable;
    sdio_writel(func, 0x55, 0x24, &err);
    pr_info("syslink_sdio: magic write result=%d\n", err);
    if (err) goto disable;
    memset(connect + 16, 0xa5, 8);
    heartbeat[16] = 0x01; heartbeat[18] = 0x6c; heartbeat[19] = 0x73;
    sdio_release_host(func);
    while (!kthread_should_stop()) {
        unsigned int header, port, mask;
        sdio_claim_host(func);
        count = sdio_readl(func, 0x0c, &err);
        if (err) { sdio_release_host(func); break; }
        if (count >= 2 && count <= 2048) {
            err = sdio_readsb(func, data, 0, count);
            if (err) { sdio_release_host(func); break; }
            header = data[0] | (data[1] << 8);
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
            } else if (header != last_header) {
                pr_info("syslink_sdio: new packet count=%u header=%04x\n", count, header);

            }
            last_header = header;
        } else if (count) {
            pr_info("syslink_sdio: unsupported packet size=%u\n", count);
            sdio_release_host(func);
            break;
        }
        if ((acknowledged & (1u << 2)) && time_after_eq(jiffies, next_heartbeat)) {
            err = sdio_writesb(func, 0, heartbeat, sizeof(heartbeat));
            if (err) { pr_info("syslink_sdio: heartbeat failed %d\n", err); sdio_release_host(func); break; }
            next_heartbeat = jiffies + msecs_to_jiffies(500);
            heartbeat_count++;
            if (heartbeat_count == 1 || heartbeat_count % 20 == 0)
                pr_info("syslink_sdio: heartbeats sent=%u\n", heartbeat_count);
        }
        sdio_release_host(func);
        msleep(10);
    }
    pr_info("syslink_sdio: stopped requested=%04x acknowledged=%04x heartbeats=%u err=%d\n", requested, acknowledged, heartbeat_count, err);
    sdio_claim_host(func);

disable:
    sdio_disable_func(func);
out:
    sdio_release_host(func);
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
static int __init diag_init(void) { return sdio_register_driver(&driver); }
static void __exit diag_exit(void) { sdio_unregister_driver(&driver); }
module_init(diag_init);
module_exit(diag_exit);
MODULE_LICENSE("GPL");
