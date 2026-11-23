#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/gpio.h>
#include <linux/gpio/consumer.h>
#include <linux/gpio/driver.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/string.h>

extern int bsp_sdio_rescan(int slot);

#define IOCFG_BASE 0x100c0000
#define EDGE_MAX 256

static unsigned int bit_us;
module_param(bit_us, uint, 0444);
static int tx_gpio, rx_gpio, rx_irq;
static bool capture;
static u64 edge_ns[EDGE_MAX];
static unsigned char edge_level[EDGE_MAX];
static unsigned int edges, dropped;

static int find_gpio4(struct gpio_chip *chip, void *unused)
{
    (void)unused;
    return chip->label && !strcmp(chip->label, "120b4000.gpio_chip");
}

static void send_byte(unsigned char byte)
{
    unsigned int i;
    gpio_set_value(tx_gpio, 0);
    udelay(bit_us);
    for (i = 0; i < 8; i++) {
        gpio_set_value(tx_gpio, (byte >> i) & 1);
        udelay(bit_us);
    }
    gpio_set_value(tx_gpio, 1);
    udelay(bit_us);
}

static irqreturn_t trace_irq(int irq, void *arg)
{
    (void)irq;
    (void)arg;
    if (!READ_ONCE(capture))
        return IRQ_HANDLED;
    if (edges < EDGE_MAX) {
        edge_ns[edges] = ktime_get_ns();
        edge_level[edges] = !!gpio_get_value(rx_gpio);
        edges++;
    } else {
        dropped++;
    }
    return IRQ_HANDLED;
}

static int __init trace_init(void)
{
    struct gpio_chip *chip;
    void __iomem *mux;
    unsigned long flags;
    u32 old_clk, old_cmd;
    int old_tx_dir, old_rx_dir, old_tx_value, old_rx_value, ret;
    unsigned int i;
    u64 start;
    unsigned char frame[10] = {0}, check = 0;
    bool valid = false;

    if (bit_us < 8 || bit_us > 200)
        return -EINVAL;
    chip = gpiochip_find(NULL, find_gpio4);
    if (!chip || chip->base < 0 || chip->ngpio < 2)
        return -ENODEV;
    tx_gpio = chip->base;
    rx_gpio = chip->base + 1;
    ret = gpio_request(tx_gpio, "syslink-trace-tx");
    if (ret) return ret;
    ret = gpio_request(rx_gpio, "syslink-trace-rx");
    if (ret) goto free_tx;
    mux = ioremap(IOCFG_BASE, 0x1000);
    if (!mux) { ret = -ENOMEM; goto free_rx; }
    old_clk = readl(mux + 0x40);
    old_cmd = readl(mux + 0x44);
    old_tx_dir = gpiod_get_direction(gpio_to_desc(tx_gpio));
    old_rx_dir = gpiod_get_direction(gpio_to_desc(rx_gpio));
    old_tx_value = gpio_get_value(tx_gpio);
    old_rx_value = gpio_get_value(rx_gpio);
    if (old_tx_dir < 0 || old_rx_dir < 0) { ret = -EIO; goto unmap_only; }
    ret = gpio_direction_input(rx_gpio);
    if (ret) goto restore;
    ret = gpio_direction_output(tx_gpio, 1);
    if (ret) goto restore;
    rx_irq = gpio_to_irq(rx_gpio);
    if (rx_irq < 0) { ret = rx_irq; goto restore; }
    writel(0x1a00, mux + 0x40);
    writel(0x1100, mux + 0x44);
    udelay(bit_us * 2);
    local_irq_save(flags);
    send_byte(0x01); send_byte(0x02); send_byte(0x00);
    local_irq_restore(flags);
    preempt_disable();
    start = ktime_get_ns();
    {
        int level = !!gpio_get_value(rx_gpio);
        u64 now;
        do {
            int next = !!gpio_get_value(rx_gpio);
            now = ktime_get_ns();
            if (next != level) {
                if (edges < EDGE_MAX) {
                    edge_ns[edges] = now;
                    edge_level[edges++] = next;
                } else dropped++;
                level = next;
            }
        } while (now - start < 50000000ULL &&
                 (!edges || now - edge_ns[0] < 1180000ULL));
    }
    if (edges && edge_level[0] == 0) {
        unsigned int byte, bit, k;
        for (byte = 0; byte < 10; byte++) {
            for (bit = 0; bit < 8; bit++) {
                u64 at = edge_ns[0] + (u64)(byte * 20 + 3 + bit * 2) * 5800;
                int level = 1;
                for (k = 0; k < edges && edge_ns[k] <= at; k++)
                    level = edge_level[k];
                frame[byte] |= level << bit;
            }
        }
        for (i = 0; i < 9; i++) check ^= frame[i];
        valid = frame[0] == 8 && !memcmp(frame + 1, "poweron\0", 8) &&
                (unsigned char)~check == frame[9];
        if (valid) {
            local_irq_save(flags);
            send_byte(0x02); send_byte(0x03); send_byte(0x01);
            local_irq_restore(flags);
        }
    }
    preempt_enable();
    pr_info("syslink_poll: valid=%u ack=%u frame=%*ph\n", valid, valid, 10, frame);
    pr_info("syslink_poll: bit_us=%u edges=%u dropped=%u\n", bit_us, edges, dropped);
    ret = 0;
restore:
    if (old_tx_dir) gpio_direction_input(tx_gpio);
    else gpio_direction_output(tx_gpio, old_tx_value);
    if (old_rx_dir) gpio_direction_input(rx_gpio);
    else gpio_direction_output(rx_gpio, old_rx_value);
    if (valid) {
        writel(0x1a04, mux + 0x40);
        writel(0x1104, mux + 0x54);
        writel(0x1104, mux + 0x44);
        writel(0, mux + 0x50);
        pr_info("syslink_poll: original SDIO mux restored, rescan=%d\n", bsp_sdio_rescan(1));
    } else {
        writel(old_clk, mux + 0x40);
        writel(old_cmd, mux + 0x44);
    }
unmap_only:
    iounmap(mux);
free_rx:
    gpio_free(rx_gpio);
free_tx:
    gpio_free(tx_gpio);
    return ret;
}
static void __exit trace_exit(void) { }
module_init(trace_init);
module_exit(trace_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Temporary GPIO edge capture for board-specific syslink");
