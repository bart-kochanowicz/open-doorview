#!/bin/sh
set -eu

stage=$1
root=${DOORVIEW_ROOT:-}
mounts=${DOORVIEW_MOUNTS:-/proc/mounts}
minimum_free_kb=${DOORVIEW_MIN_FREE_KB:-300}

module_dir=$root/etc/doorview
lcd_dir=$root/etc/doorview-lcd
init_dir=$root/etc/init.d
network_hook=$init_dir/S41doorview-network
lcd_hook=$init_dir/S96doorview-lcd
irq_module=$module_dir/syslink_net_irq.ko
previous_hook=$module_dir/S41doorview-network.previous

# The exact files this update replaces or builds on.
old_network_sha=136f3b2ad0117f600a98b096d9f0d03e0b715a27dfb43a4b8416e735e1b58724
old_module_sha=cfd9dd4f2dd41d30d0521f79cc11bb14281d7aee2f9bea17dcfdc1734aa7b585

stage_files='S41doorview-network S96doorview-lcd syslink_net_irq.ko service vo.ko libuclibc-compat.so vo-live-30 button-preview live-30.sh'
lcd_files='service vo.ko libuclibc-compat.so vo-live-30 button-preview live-30.sh'

digest() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

free_kb() {
    if [ -n "${DOORVIEW_FREE_KB:-}" ]; then
        echo "$DOORVIEW_FREE_KB"
    else
        df -k /overlay | awk 'NR == 2 { print $4 }'
    fi
}

absent() {
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

awk '
    $2 == "/" && $3 == "overlay" { root_overlay = 1 }
    $1 == "/dev/mtdblock5" && $2 == "/overlay" && $3 == "jffs2" { data = 1 }
    $2 == "/etc" || $2 == "/etc/doorview" || $2 == "/etc/doorview-lcd" || $2 == "/etc/init.d" { masked = 1 }
    END { exit !(root_overlay && data && !masked) }
' "$mounts"

[ -d "$module_dir" ] && [ ! -L "$module_dir" ] || exit 1
[ -d "$init_dir" ] && [ ! -L "$init_dir" ] || exit 1
for name in $stage_files; do
    [ -f "$stage/$name" ] && [ ! -L "$stage/$name" ] || exit 1
done
[ -f "$stage/SHA256SUMS" ] || exit 1
while read -r sum name; do
    [ "$(digest "$stage/$name")" = "$sum" ] || exit 1
done < "$stage/SHA256SUMS"

# Only update the exact Wi-Fi startup that was tested, and never overwrite state.
[ "$(digest "$network_hook")" = "$old_network_sha" ] || exit 1
[ "$(digest "$module_dir/syslink_net.ko")" = "$old_module_sha" ] || exit 1
[ -r "$module_dir/station.hex" ] && [ -r "$module_dir/address" ] && [ -r "$module_dir/mac" ] || exit 1
absent "$lcd_dir" && absent "$lcd_hook" && absent "$irq_module" && absent "$previous_hook" || exit 1
[ "$(free_kb)" -ge "$minimum_free_kb" ] || exit 1

lcd_tmp=
module_tmp=
hook_tmp=
lcd_done=no
previous_done=no
irq_done=no
network_done=no
lcd_hook_done=no
committed=no

cleanup() {
    result=$?
    set +e
    if [ "$committed" = no ]; then
        [ "$lcd_hook_done" = no ] || rm -f "$lcd_hook"
        if [ "$network_done" = yes ]; then
            restore_tmp=$(mktemp "$init_dir/.doorview.XXXXXX")
            if cp "$previous_hook" "$restore_tmp" && chmod 755 "$restore_tmp" && mv "$restore_tmp" "$network_hook"; then
                :
            else
                rm -f "$restore_tmp"
                echo 'ROLLBACK_FAILED: restore S41doorview-network from S41doorview-network.previous' >&2
            fi
        fi
        [ "$irq_done" = no ] || rm -f "$irq_module"
        [ "$previous_done" = no ] || rm -f "$previous_hook"
        [ "$lcd_done" = no ] || rm -rf "$lcd_dir"
    fi
    [ -z "$lcd_tmp" ] || rm -rf "$lcd_tmp"
    [ -z "$module_tmp" ] || rm -rf "$module_tmp"
    [ -z "$hook_tmp" ] || rm -f "$hook_tmp"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

lcd_tmp=$(mktemp -d "$root/etc/.doorview-lcd.XXXXXX")
module_tmp=$(mktemp -d "$module_dir/.lcd-irq-install.XXXXXX")
hook_tmp=$(mktemp "$init_dir/.doorview.XXXXXX")

for name in $lcd_files; do
    cp "$stage/$name" "$lcd_tmp/$name"
    cmp -s "$stage/$name" "$lcd_tmp/$name"
    case "$name" in
        service|vo.ko|live-30.sh) chmod 600 "$lcd_tmp/$name" ;;
        *) chmod 700 "$lcd_tmp/$name" ;;
    esac
done
chmod 700 "$lcd_tmp"
cp "$stage/syslink_net_irq.ko" "$module_tmp/syslink_net_irq.ko"
cmp -s "$stage/syslink_net_irq.ko" "$module_tmp/syslink_net_irq.ko"
chmod 600 "$module_tmp/syslink_net_irq.ko"
cp "$stage/S41doorview-network" "$hook_tmp"
cmp -s "$stage/S41doorview-network" "$hook_tmp"
chmod 755 "$hook_tmp"

# Keep the replaced S41 outside init.d so it can be restored.
cp "$network_hook" "$previous_hook"
cmp -s "$network_hook" "$previous_hook"
chmod 600 "$previous_hook"
previous_done=yes

mv "$lcd_tmp" "$lcd_dir"
lcd_tmp=
lcd_done=yes
mv "$module_tmp/syslink_net_irq.ko" "$irq_module"
irq_done=yes
mv "$hook_tmp" "$network_hook"
hook_tmp=
network_done=yes

# S96 is last: it only appears after every file it needs is in place.
hook_tmp=$(mktemp "$init_dir/.doorview.XXXXXX")
cp "$stage/S96doorview-lcd" "$hook_tmp"
cmp -s "$stage/S96doorview-lcd" "$hook_tmp"
chmod 755 "$hook_tmp"
mv "$hook_tmp" "$lcd_hook"
hook_tmp=
lcd_hook_done=yes

cmp -s "$stage/S41doorview-network" "$network_hook"
cmp -s "$stage/S96doorview-lcd" "$lcd_hook"
cmp -s "$stage/syslink_net_irq.ko" "$irq_module"
for name in $lcd_files; do
    cmp -s "$stage/$name" "$lcd_dir/$name"
done
[ "$(digest "$previous_hook")" = "$old_network_sha" ]
[ "$(digest "$module_dir/syslink_net.ko")" = "$old_module_sha" ]
sync
committed=yes
echo LCD_IRQ_INSTALLED
