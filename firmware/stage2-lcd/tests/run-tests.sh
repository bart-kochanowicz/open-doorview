#!/bin/sh
# Local fixture tests. They never touch the camera; everything runs under a temporary root.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
old_candidate=${OLD_CANDIDATE:-$here/../stage1-wifi}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

check() {
    description=$1
    shift
    if "$@" > /dev/null 2>&1; then
        passed=$((passed + 1))
        echo "ok   - $description"
    else
        failed=$((failed + 1))
        echo "FAIL - $description"
    fi
}

check_fails() {
    description=$1
    shift
    if "$@" > /dev/null 2>&1; then
        failed=$((failed + 1))
        echo "FAIL - $description (command succeeded)"
    else
        passed=$((passed + 1))
        echo "ok   - $description"
    fi
}

digest() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

tree_state() {
    (cd "$1" && find . -type f | sort | while read -r file; do printf '%s %s\n' "$(digest "$file")" "$file"; done; find . -type d | sort)
}

build_stage() {
    target=$1
    mkdir -p "$target"
    cp "$here/payload/etc/init.d/S41doorview-network" "$here/payload/etc/init.d/S96doorview-lcd" "$target/"
    cp "$here/payload/etc/doorview/syslink_net_irq.ko" "$target/"
    for name in service libuclibc-compat.so vo-live-30 button-preview live-30.sh; do
        cp "$here/payload/etc/doorview-lcd/$name" "$target/"
    done
    # vo.ko is a vendor blob that is not stored in this repository; the installer only needs some file here.
    printf 'placeholder for the vendor VO module\n' > "$target/vo.ko"
    (cd "$target" && for name in S41doorview-network S96doorview-lcd syslink_net_irq.ko service vo.ko libuclibc-compat.so vo-live-30 button-preview live-30.sh; do shasum -a 256 "$name"; done > SHA256SUMS)
}

build_root() {
    fixture=$1
    mkdir -p "$fixture/etc/doorview" "$fixture/etc/init.d"
    cp "$old_candidate/payload/etc/init.d/S41doorview-network" "$fixture/etc/init.d/S41doorview-network"
    cp "$old_candidate/payload/etc/doorview/syslink_net.ko" "$fixture/etc/doorview/syslink_net.ko"
    printf '%s\n' "$(printf 'ab%.0s' $(seq 1 64))" > "$fixture/etc/doorview/station.hex"
    printf '192.0.2.10/24\n' > "$fixture/etc/doorview/address"
    printf '02:00:00:00:00:01\n' > "$fixture/etc/doorview/mac"
    printf 'bg\n' > "$fixture/etc/doorview/syslink_bg.ko"
    printf 'poll\n' > "$fixture/etc/doorview/syslink_poll.ko"
    printf '#!/bin/sh\n' > "$fixture/etc/init.d/S95majestic"
    chmod 600 "$fixture/etc/doorview/station.hex"
}

mounts_ok="$work/mounts-ok"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\n' > "$mounts_ok"
mounts_masked="$work/mounts-masked"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\ntmpfs /etc/doorview tmpfs rw 0 0\n' > "$mounts_masked"

stage="$work/stage"
build_stage "$stage"

install() {
    DOORVIEW_ROOT=$1 DOORVIEW_MOUNTS=${2:-$mounts_ok} DOORVIEW_FREE_KB=${3:-388} sh "$here/install.sh" "$stage"
}

echo '== install.sh =='

root="$work/root-success"
build_root "$root"
before=$(tree_state "$root")
check 'installs on the tested layout' install "$root"
check 'installed S41 matches payload' cmp -s "$stage/S41doorview-network" "$root/etc/init.d/S41doorview-network"
check 'installed S96 matches payload and is last hook' cmp -s "$stage/S96doorview-lcd" "$root/etc/init.d/S96doorview-lcd"
check 'IRQ module installed' cmp -s "$stage/syslink_net_irq.ko" "$root/etc/doorview/syslink_net_irq.ko"
check 'polling module untouched' cmp -s "$old_candidate/payload/etc/doorview/syslink_net.ko" "$root/etc/doorview/syslink_net.ko"
check 'station file untouched and private' test "$(stat -f %Lp "$root/etc/doorview/station.hex" 2>/dev/null || stat -c %a "$root/etc/doorview/station.hex")" = 600
check 'previous S41 kept for rollback' cmp -s "$old_candidate/payload/etc/init.d/S41doorview-network" "$root/etc/doorview/S41doorview-network.previous"
check 'LCD files installed' cmp -s "$stage/vo.ko" "$root/etc/doorview-lcd/vo.ko"
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2>/dev/null)"
check_fails 'second install is refused' install "$root"
check 'rollback succeeds' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
after=$(tree_state "$root")
check 'rollback restores the exact original tree' test "$before" = "$after"

root="$work/root-tampered"
build_root "$root"
printf '# changed\n' >> "$root/etc/init.d/S41doorview-network"
before=$(tree_state "$root")
check_fails 'refuses an unexpected S41' install "$root"
check 'refusal changes nothing (unexpected S41)' test "$before" = "$(tree_state "$root")"

root="$work/root-module"
build_root "$root"
printf 'x' >> "$root/etc/doorview/syslink_net.ko"
before=$(tree_state "$root")
check_fails 'refuses an unexpected polling module' install "$root"
check 'refusal changes nothing (unexpected module)' test "$before" = "$(tree_state "$root")"

root="$work/root-space"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses when free space is too small' install "$root" "$mounts_ok" 120
check 'refusal changes nothing (low space)' test "$before" = "$(tree_state "$root")"

root="$work/root-masked"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses when /etc/doorview is masked by another mount' install "$root" "$mounts_masked"
check 'refusal changes nothing (masked mount)' test "$before" = "$(tree_state "$root")"

root="$work/root-existing"
build_root "$root"
mkdir -p "$root/etc/doorview-lcd"
before=$(tree_state "$root")
check_fails 'refuses an existing /etc/doorview-lcd' install "$root"
check 'refusal changes nothing (existing target)' test "$before" = "$(tree_state "$root")"

root="$work/root-missing-config"
build_root "$root"
rm "$root/etc/doorview/station.hex"
check_fails 'refuses without station configuration' install "$root"

bad_stage="$work/stage-bad"
build_stage "$bad_stage"
printf 'x' >> "$bad_stage/vo.ko"
root="$work/root-bad-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage file that does not match SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=388 sh "$here/install.sh" "$bad_stage"
check 'refusal changes nothing (bad stage)' test "$before" = "$(tree_state "$root")"

shim="$work/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' > "$shim/sync"
chmod 755 "$shim/sync"
root="$work/root-rollback"
build_root "$root"
before=$(tree_state "$root")
check_fails 'a failure after every file is in place fails the install' env PATH="$shim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=388 sh "$here/install.sh" "$stage"
check 'failed install rolls back to the exact original tree' test "$before" = "$(tree_state "$root")"

# A manifest that does not cover every installed file must not let an unverified file through.
empty_stage="$work/stage-empty-manifest"
build_stage "$empty_stage"
printf 'x' >> "$empty_stage/vo-live-30"
: > "$empty_stage/SHA256SUMS"
root="$work/root-empty-manifest"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses an empty SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=388 sh "$here/install.sh" "$empty_stage"
check 'refusal changes nothing (empty manifest)' test "$before" = "$(tree_state "$root")"
short_stage="$work/stage-short-manifest"
build_stage "$short_stage"
grep -v ' vo-live-30$' "$short_stage/SHA256SUMS" > "$short_stage/SHA256SUMS.new"
mv "$short_stage/SHA256SUMS.new" "$short_stage/SHA256SUMS"
root="$work/root-short-manifest"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a SHA256SUMS that omits a payload file' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=388 sh "$here/install.sh" "$short_stage"
check 'refusal changes nothing (short manifest)' test "$before" = "$(tree_state "$root")"

# If restoring the old S41 also fails, the backup is the only copy left and must be kept.
real_mktemp=$(command -v mktemp)
mkshim="$work/mktemp-shim"
mkdir -p "$mkshim"
cp "$shim/sync" "$mkshim/sync"
cat > "$mkshim/mktemp" << EOF
#!/bin/sh
count=\$(cat "$work/mktemp-count" 2> /dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "$work/mktemp-count"
[ "\$count" -gt 4 ] && exit 1
exec "$real_mktemp" "\$@"
EOF
chmod 755 "$mkshim/mktemp"
rm -f "$work/mktemp-count"
root="$work/root-restore-fails"
build_root "$root"
old_sum=$(digest "$root/etc/init.d/S41doorview-network")
check_fails 'an install whose restore also fails reports failure' env PATH="$mkshim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=388 sh "$here/install.sh" "$stage"
check 'the backup of the old S41 is kept when the restore failed' test "$(digest "$root/etc/doorview/S41doorview-network.previous" 2> /dev/null)" = "$old_sum"
check 'a failed restore does not write a stray copy into the working directory' test ! -e "./S41doorview-network.previous"

echo '== S41doorview-network =='

bin="$work/bin"
mkdir -p "$bin"
cat > "$bin/dmesg" <<'EOF'
#!/bin/sh
printf 'syslink_sdio: port=0 confirmed, ack result=0\nsyslink_sdio: port=2 confirmed, ack result=0\nsyslink_sdio: port=3 confirmed, ack result=0\n'
EOF
cat > "$bin/insmod" <<'EOF'
#!/bin/sh
echo "insmod $*" >> "$LOG"
name=$(basename "$1")
case ",${FAIL_INSMOD:-}," in *",$name,"*) exit 1 ;; esac
case "$name" in
    syslink_net*.ko) mkdir -p "$DOORVIEW_SYS_MODULE/syslink_net/parameters"; : > "$DOORVIEW_SYS_MODULE/syslink_net/parameters/station" ;;
    syslink_bg.ko) mkdir -p "$DOORVIEW_SYS_MODULE/syslink_bg" ;;
esac
EOF
cat > "$bin/rmmod" <<'EOF'
#!/bin/sh
echo "rmmod $*" >> "$LOG"
rm -rf "$DOORVIEW_SYS_MODULE/$1"
EOF
cat > "$bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >> "$LOG"
[ -z "${FAIL_IP:-}" ]
EOF
printf '#!/bin/sh\nexit 0\n' > "$bin/sleep"
chmod 755 "$bin/dmesg" "$bin/insmod" "$bin/rmmod" "$bin/ip" "$bin/sleep"

run_s41() {
    # $1 = case name; remaining environment is passed through.
    case_dir="$work/s41-$1"
    rm -rf "$case_dir"
    mkdir -p "$case_dir/sys/syslink_bg" "$case_dir/etc"
    cp "$root/etc/doorview/"* "$case_dir/etc/" 2>/dev/null
    cp "$here/payload/etc/doorview/syslink_net_irq.ko" "$case_dir/etc/syslink_net_irq.ko"
    printf 'old\n' > "$case_dir/etc/syslink_net.ko"
    LOG="$case_dir/log"
    : > "$LOG"
    export LOG
    DOORVIEW_MODULE_DIR="$case_dir/etc" DOORVIEW_SYS_MODULE="$case_dir/sys" PATH="$bin:$PATH" sh "$here/payload/etc/init.d/S41doorview-network" start
}

root="$work/root-s41"
build_root "$root"

# IRQ driver is preferred.
check 'IRQ driver starts' run_s41 irq
check 'IRQ driver gets GPIO36 and IRQ receive' grep -q 'insmod .*syslink_net_irq.ko resume_connected=1 tx_max_len=768 rx_burst=1 rx_gpio=36 irq_rx=1 rx_poll_ms=100' "$work/s41-irq/log"
check 'polling driver is not loaded when IRQ works' test -z "$(grep 'syslink_net.ko' "$work/s41-irq/log")"
check 'station request is passed to the driver' cmp -s "$work/s41-irq/etc/station.hex" "$work/s41-irq/sys/syslink_net/parameters/station"
check 'MAC, MTU, address and link-up are configured' sh -c "grep -c '^ip link set dev dv0' '$work/s41-irq/log' | grep -q 3 && grep -q '^ip addr add 192.0.2.10/24 dev dv0' '$work/s41-irq/log'"

# Falls back to the polling driver when the IRQ driver cannot load.
( FAIL_INSMOD=syslink_net_irq.ko; export FAIL_INSMOD; run_s41 fallback ) > /dev/null 2>&1
check 'fallback leaves the polling driver loaded' test -d "$work/s41-fallback/sys/syslink_net"
check 'fallback loads the polling driver without IRQ parameters' grep -q 'insmod .*syslink_net.ko resume_connected=1 tx_max_len=768 rx_burst=1$' "$work/s41-fallback/log"
check 'IRQ driver was unloaded before the fallback' grep -q '^rmmod syslink_net$' "$work/s41-fallback/log"

# Both drivers fail network setup: the SDIO heartbeat driver is restored.
( FAIL_IP=1; export FAIL_IP; run_s41 bothfail ) > /dev/null 2>&1
check 'both drivers failing restores the SDIO heartbeat' grep -q '^insmod .*syslink_bg.ko resume_connected=1' "$work/s41-bothfail/log"
check 'heartbeat restore leaves no syslink_net module' test ! -d "$work/s41-bothfail/sys/syslink_net"

# Missing IRQ module: unchanged polling behaviour.
case_dir="$work/s41-noirq"
rm -rf "$case_dir"
mkdir -p "$case_dir/sys/syslink_bg" "$case_dir/etc"
cp "$root/etc/doorview/"* "$case_dir/etc/"
printf 'old\n' > "$case_dir/etc/syslink_net.ko"
LOG="$case_dir/log"; : > "$LOG"; export LOG
DOORVIEW_MODULE_DIR="$case_dir/etc" DOORVIEW_SYS_MODULE="$case_dir/sys" PATH="$bin:$PATH" sh "$here/payload/etc/init.d/S41doorview-network" start > /dev/null 2>&1
check 'without the IRQ module it behaves like the old startup' grep -q 'insmod .*syslink_net.ko resume_connected=1 tx_max_len=768 rx_burst=1$' "$case_dir/log"

# Already running: do nothing.
case_dir="$work/s41-running"
rm -rf "$case_dir"
mkdir -p "$case_dir/sys/syslink_bg" "$case_dir/sys/syslink_net" "$case_dir/etc"
cp "$root/etc/doorview/"* "$case_dir/etc/"
LOG="$case_dir/log"; : > "$LOG"; export LOG
check 'does nothing when syslink_net is already loaded' env DOORVIEW_MODULE_DIR="$case_dir/etc" DOORVIEW_SYS_MODULE="$case_dir/sys" PATH="$bin:$PATH" sh "$here/payload/etc/init.d/S41doorview-network" start
check 'nothing was loaded in that case' test ! -s "$case_dir/log"

echo '== S96doorview-lcd =='

case_dir="$work/s96"
mkdir -p "$case_dir"
cat > "$case_dir/service" <<'SERVICE'
#!/bin/sh
echo "service $*" >> "$LOG"
[ "$1" != start ] || sleep 3
SERVICE
LOG="$case_dir/log"; : > "$LOG"; export LOG
start_seconds=$(python3 -c 'import time; print(time.time())')
DOORVIEW_LCD_SERVICE="$case_dir/service" DOORVIEW_LCD_DELAY=1 sh "$here/payload/etc/init.d/S96doorview-lcd" start
start_rc=$?
elapsed=$(python3 -c "import time; print(time.time() - $start_seconds)")
check 'start returns success' test "$start_rc" = 0
check 'start does not wait for the delayed service' python3 -c "import sys; sys.exit(0 if $elapsed < 0.8 else 1)"
for attempt in 1 2 3 4 5 6 7 8 9 10; do grep -q 'service start' "$LOG" && break; python3 -c 'import time; time.sleep(0.5)'; done
check 'the service is started in the background' grep -q 'service start' "$LOG"
DOORVIEW_LCD_SERVICE="$case_dir/service" sh "$here/payload/etc/init.d/S96doorview-lcd" stop
check 'stop is passed to the service immediately' grep -q 'service stop' "$LOG"
DOORVIEW_LCD_SERVICE="$case_dir/service" sh "$here/payload/etc/init.d/S96doorview-lcd" status
check 'status is passed to the service' grep -q 'service status' "$LOG"
check_fails 'an unknown action is rejected' env DOORVIEW_LCD_SERVICE="$case_dir/service" sh "$here/payload/etc/init.d/S96doorview-lcd" bogus

echo "passed=$passed failed=$failed"
[ "$failed" = 0 ]
