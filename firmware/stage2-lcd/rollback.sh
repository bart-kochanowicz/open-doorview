#!/bin/sh
set -eu

# Restores the Wi-Fi startup that was in place before install.sh and removes the LCD button service.
root=${DOORVIEW_ROOT:-}
module_dir=$root/etc/doorview
lcd_dir=$root/etc/doorview-lcd
init_dir=$root/etc/init.d
network_hook=$init_dir/S41doorview-network
lcd_hook=$init_dir/S96doorview-lcd
irq_module=$module_dir/syslink_net_irq.ko
previous_hook=$module_dir/S41doorview-network.previous
old_network_sha=136f3b2ad0117f600a98b096d9f0d03e0b715a27dfb43a4b8416e735e1b58724

digest() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

[ -f "$previous_hook" ] && [ "$(digest "$previous_hook")" = "$old_network_sha" ] || exit 1
[ -d "$module_dir" ] && [ ! -L "$module_dir" ] && [ -d "$init_dir" ] && [ ! -L "$init_dir" ] || exit 1

restore_tmp=$(mktemp "$init_dir/.doorview.XXXXXX")
trap 'rm -f "$restore_tmp"' EXIT
cp "$previous_hook" "$restore_tmp"
cmp -s "$previous_hook" "$restore_tmp"
chmod 755 "$restore_tmp"

# Remove the LCD hook first, then put the previous Wi-Fi startup back.
rm -f "$lcd_hook"
mv "$restore_tmp" "$network_hook"
[ "$(digest "$network_hook")" = "$old_network_sha" ]
rm -rf "$lcd_dir"
rm -f "$irq_module" "$previous_hook"
sync
echo LCD_IRQ_ROLLED_BACK
