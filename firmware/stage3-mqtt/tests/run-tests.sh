#!/bin/sh
# Local fixture tests for the MQTT candidate. They never touch the camera; everything runs under a temporary root.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
old_candidate=${OLD_CANDIDATE:-$here/../stage2-lcd}
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

mode_of() {
    stat -f %Lp "$1" 2> /dev/null || stat -c %a "$1"
}

tree_state() {
    (cd "$1" && find . -type f | sort | while read -r file; do printf '%s %s\n' "$(digest "$file")" "$file"; done; find . -type d | sort)
}

build_stage() {
    target=$1
    mkdir -p "$target"
    cp "$here/payload/etc/doorview/syslink_net_irq.ko" "$here/payload/etc/doorview/doorview-mqtt" "$here/payload/etc/init.d/S97doorview-mqtt" "$target/"
    (cd "$target" && for name in syslink_net_irq.ko doorview-mqtt S97doorview-mqtt; do shasum -a 256 "$name"; done > SHA256SUMS)
}

build_root() {
    fixture=$1
    mkdir -p "$fixture/etc/doorview" "$fixture/etc/init.d"
    cp "$old_candidate/payload/etc/doorview/syslink_net_irq.ko" "$fixture/etc/doorview/syslink_net_irq.ko"
    printf '%s\n' "$(printf 'ab%.0s' $(seq 1 64))" > "$fixture/etc/doorview/station.hex"
    printf '192.0.2.10/24\n' > "$fixture/etc/doorview/address"
    printf 'bg\n' > "$fixture/etc/doorview/syslink_bg.ko"
    printf '#!/bin/sh\n' > "$fixture/etc/init.d/S41doorview-network"
    printf '#!/bin/sh\n' > "$fixture/etc/init.d/S96doorview-lcd"
    chmod 600 "$fixture/etc/doorview/station.hex" "$fixture/etc/doorview/syslink_net_irq.ko"
}

# wait_for_lines <file> <count> <seconds>: the stub daemon logs asynchronously.
wait_for_lines() {
    waited=0
    while [ "$waited" -lt "$(($3 * 10))" ]; do
        [ "$(wc -l < "$1" | tr -d ' ')" -ge "$2" ] && return 0
        python3 -c 'import time; time.sleep(0.1)'
        waited=$((waited + 1))
    done
    return 1
}

mounts_ok="$work/mounts-ok"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\n' > "$mounts_ok"
mounts_masked="$work/mounts-masked"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\ntmpfs /etc/doorview tmpfs rw 0 0\n' > "$mounts_masked"

stage="$work/stage"
build_stage "$stage"

install() {
    DOORVIEW_ROOT=$1 DOORVIEW_MOUNTS=${2:-$mounts_ok} DOORVIEW_FREE_KB=${3:-288} sh "$here/install.sh" "$stage"
}

echo '== install.sh =='

root="$work/root-success"
build_root "$root"
before=$(tree_state "$root")
station_before=$(digest "$root/etc/doorview/station.hex")
check 'installs on the tested layout' install "$root"
check 'driver is replaced by the new build' cmp -s "$stage/syslink_net_irq.ko" "$root/etc/doorview/syslink_net_irq.ko"
check 'the previous driver is kept for rollback' cmp -s "$old_candidate/payload/etc/doorview/syslink_net_irq.ko" "$root/etc/doorview/syslink_net_irq.ko.previous"
check 'daemon installed' cmp -s "$stage/doorview-mqtt" "$root/etc/doorview/doorview-mqtt"
check 'daemon is executable only by its owner' test "$(mode_of "$root/etc/doorview/doorview-mqtt")" = 700
check 'driver files are private' test "$(mode_of "$root/etc/doorview/syslink_net_irq.ko")" = 600
check 'boot hook installed and executable' test -x "$root/etc/init.d/S97doorview-mqtt"
check 'the Wi-Fi startup and LCD hooks are untouched' sh -c "test \"\$(cat '$root/etc/init.d/S41doorview-network')\" = '#!/bin/sh' && test \"\$(cat '$root/etc/init.d/S96doorview-lcd')\" = '#!/bin/sh'"
check 'station configuration is untouched' test "$(digest "$root/etc/doorview/station.hex")" = "$station_before"
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
check_fails 'a second install is refused' install "$root"
check 'rollback succeeds' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'rollback restores the exact original tree' test "$before" = "$(tree_state "$root")"

root="$work/root-driver"
build_root "$root"
printf 'x' >> "$root/etc/doorview/syslink_net_irq.ko"
before=$(tree_state "$root")
check_fails 'refuses an unexpected installed driver' install "$root"
check 'refusal changes nothing (unexpected driver)' test "$before" = "$(tree_state "$root")"

root="$work/root-space"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses when free space is too small' install "$root" "$mounts_ok" 60
check 'refusal changes nothing (low space)' test "$before" = "$(tree_state "$root")"

root="$work/root-masked"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses when /etc/doorview is masked by another mount' install "$root" "$mounts_masked"
check 'refusal changes nothing (masked mount)' test "$before" = "$(tree_state "$root")"

root="$work/root-existing"
build_root "$root"
printf 'x' > "$root/etc/doorview/doorview-mqtt"
before=$(tree_state "$root")
check_fails 'refuses when a daemon already exists' install "$root"
check 'refusal changes nothing (existing daemon)' test "$before" = "$(tree_state "$root")"

bad_stage="$work/stage-bad"
build_stage "$bad_stage"
printf 'x' >> "$bad_stage/doorview-mqtt"
root="$work/root-bad-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage file that does not match SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$bad_stage"
check 'refusal changes nothing (bad stage)' test "$before" = "$(tree_state "$root")"

shim="$work/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' > "$shim/sync"
chmod 755 "$shim/sync"
root="$work/root-rollback"
build_root "$root"
before=$(tree_state "$root")
check_fails 'a failure after every file is in place fails the install' env PATH="$shim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
check 'failed install rolls back to the exact original tree' test "$before" = "$(tree_state "$root")"

# A manifest that does not cover every installed file must not let an unverified file through.
empty_stage="$work/stage-empty-manifest"
build_stage "$empty_stage"
printf 'x' >> "$empty_stage/doorview-mqtt"
: > "$empty_stage/SHA256SUMS"
root="$work/root-empty-manifest"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses an empty SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$empty_stage"
check 'refusal changes nothing (empty manifest)' test "$before" = "$(tree_state "$root")"
short_stage="$work/stage-short-manifest"
build_stage "$short_stage"
grep -v ' doorview-mqtt$' "$short_stage/SHA256SUMS" > "$short_stage/SHA256SUMS.new"
mv "$short_stage/SHA256SUMS.new" "$short_stage/SHA256SUMS"
root="$work/root-short-manifest"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a SHA256SUMS that omits a payload file' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$short_stage"
check 'refusal changes nothing (short manifest)' test "$before" = "$(tree_state "$root")"

# If restoring the old driver also fails, the backup is the only copy left and must be kept.
real_mktemp=$(command -v mktemp)
mkshim="$work/mktemp-shim"
mkdir -p "$mkshim"
cp "$shim/sync" "$mkshim/sync"
cat > "$mkshim/mktemp" << EOF
#!/bin/sh
count=\$(cat "$work/mktemp-count" 2> /dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "$work/mktemp-count"
[ "\$count" -gt 2 ] && exit 1
exec "$real_mktemp" "\$@"
EOF
chmod 755 "$mkshim/mktemp"
rm -f "$work/mktemp-count"
root="$work/root-restore-fails"
build_root "$root"
old_sum=$(digest "$root/etc/doorview/syslink_net_irq.ko")
check_fails 'an install whose restore also fails reports failure' env PATH="$mkshim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
check 'the backup of the old driver is kept when the restore failed' test "$(digest "$root/etc/doorview/syslink_net_irq.ko.previous" 2> /dev/null)" = "$old_sum"
check 'a failed restore does not write a stray copy into the working directory' test ! -e "./syslink_net_irq.ko.previous"

echo '== configure.sh =='

root="$work/root-config"
build_root "$root"
cat > "$work/good.conf" << 'EOF'
host=192.0.2.20
port=1883
user=front-door-camera
password=s3cret-value
EOF
configure() {
    DOORVIEW_ROOT=$root sh "$here/configure.sh" "$@"
}
check 'a valid configuration is installed' configure "$work/good.conf"
check 'mqtt.conf is private (600)' test "$(mode_of "$root/etc/doorview/mqtt.conf")" = 600
check 'mqtt.conf matches the input' cmp -s "$work/good.conf" "$root/etc/doorview/mqtt.conf"
check_fails 'an existing configuration is not overwritten without --replace' configure "$work/good.conf"
check 'it is replaced with --replace' configure "$work/good.conf" --replace
output=$(configure "$work/good.conf" --replace 2>&1)
check 'the password is never printed' test "$(printf '%s' "$output" | grep -c 's3cret-value')" = 0
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
printf 'gateway=192.0.2.1\n' | cat "$work/good.conf" - > "$work/gateway.conf"
check 'a configuration with a gateway is installed' configure "$work/gateway.conf" --replace
check 'the gateway is kept in mqtt.conf' grep -qx 'gateway=192.0.2.1' "$root/etc/doorview/mqtt.conf"

root="$work/root-config-bad"
build_root "$root"
try_bad() {
    printf '%s\n' "$1" > "$work/bad.conf"
    DOORVIEW_ROOT=$root sh "$here/configure.sh" "$work/bad.conf"
}
check_fails 'a host name instead of an IPv4 address is rejected' try_bad "host=broker.local
user=a
password=b"
check_fails 'a missing password is rejected' try_bad "host=192.0.2.20
user=a"
check_fails 'a missing user is rejected' try_bad "host=192.0.2.20
password=b"
check_fails 'an out-of-range port is rejected' try_bad "host=192.0.2.20
port=70000
user=a
password=b"
check_fails 'a non-numeric port is rejected' try_bad "host=192.0.2.20
port=abc
user=a
password=b"
check_fails 'an unknown key is rejected' try_bad "host=192.0.2.20
user=a
password=b
command=run-this"
check_fails 'a password that is too long is rejected' try_bad "host=192.0.2.20
user=a
password=$(printf 'x%.0s' $(seq 1 80))"
check_fails 'a gateway that is not an IPv4 address is rejected' try_bad "host=192.0.2.20
user=a
password=b
gateway=router.local"
check_fails 'a gateway with extra characters is rejected' try_bad "host=192.0.2.20
user=a
password=b
gateway=192.0.2.1; reboot"
ln -s "$work/good.conf" "$work/link.conf"
check_fails 'a symlink as input is rejected' sh -c "DOORVIEW_ROOT='$root' sh '$here/configure.sh' '$work/link.conf'"
check 'rejected configurations write nothing' test ! -e "$root/etc/doorview/mqtt.conf"

echo '== S97doorview-mqtt =='

case_dir="$work/s97"
mkdir -p "$case_dir"
cat > "$case_dir/daemon" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$LOG"
while :; do sleep 1; done
EOF
chmod 755 "$case_dir/daemon"
LOG="$case_dir/log"
export LOG
: > "$LOG"
s97() {
    DOORVIEW_MQTT_DAEMON="$case_dir/daemon" DOORVIEW_MQTT_CONFIG="$case_dir/mqtt.conf" DOORVIEW_MQTT_PIDFILE="$case_dir/pid" DOORVIEW_MQTT_LOG="$case_dir/out.log" sh "$here/payload/etc/init.d/S97doorview-mqtt" "$@"
}
check 'start without a configuration does nothing and succeeds' s97 start
check 'no daemon was started without a configuration' test ! -s "$LOG"
check_fails 'status says stopped' s97 status
printf 'host=192.0.2.20\n' > "$case_dir/mqtt.conf"
check 'start with a configuration succeeds' s97 start
wait_for_lines "$LOG" 1 5
check 'the daemon was started with the configuration path' grep -qF "$case_dir/mqtt.conf" "$LOG"
check 'status says running' s97 status
check 'a second start does not start a second daemon' sh -c "DOORVIEW_MQTT_DAEMON='$case_dir/daemon' DOORVIEW_MQTT_CONFIG='$case_dir/mqtt.conf' DOORVIEW_MQTT_PIDFILE='$case_dir/pid' DOORVIEW_MQTT_LOG='$case_dir/out.log' sh '$here/payload/etc/init.d/S97doorview-mqtt' start; python3 -c 'import time; time.sleep(0.3)'; test \"\$(wc -l < '$LOG' | tr -d ' ')\" = 1"
check 'stop succeeds' s97 stop
check_fails 'status says stopped after stop' s97 status
check 'the pid file is removed' test ! -e "$case_dir/pid"
check 'restart starts it again' s97 restart
s97 stop > /dev/null 2>&1
printf '999999\n' > "$case_dir/pid"
: > "$LOG"
s97 start
wait_for_lines "$LOG" 1 5
check 'a stale pid file does not block start' test "$(wc -l < "$LOG" | tr -d ' ')" = 1
check 'the daemon is really running after a stale pid file' s97 status
s97 stop > /dev/null 2>&1
chmod 600 "$case_dir/daemon"
check_fails 'a daemon that is not executable fails the start' s97 start
check_fails 'an unknown action is rejected' s97 bogus

echo '== S97doorview-mqtt default route =='

# A stand-in for BusyBox ip(8), which is what the camera has: the route list is always the whole table
# (a "show default" selector is not applied), and DEFAULT_ROUTE adds a default entry to it.
shim="$work/ip-shim"
mkdir -p "$shim"
cat > "$shim/ip" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_LOG"
case "$*" in
    route|'route show'|'route show default')
        echo '192.0.2.0/24 dev dv0 scope link  src 192.0.2.10'
        [ -z "${DEFAULT_ROUTE:-}" ] || echo "default via $DEFAULT_ROUTE dev dv0"
        ;;
    'route add default via '*) [ -z "${IP_FAIL:-}" ] || exit 2 ;;
esac
exit 0
EOF
chmod 755 "$shim/ip"
IP_LOG="$case_dir/ip.log"
export IP_LOG
chmod 755 "$case_dir/daemon"
# $1 = configuration text, $2 = existing default route (may be empty), $3 = non-empty makes "ip route add" fail.
s97_route() {
    : > "$IP_LOG"
    : > "$LOG"
    printf '%s\n' "$1" > "$case_dir/mqtt.conf"
    env PATH="$shim:$PATH" DEFAULT_ROUTE="${2:-}" IP_FAIL="${3:-}" DOORVIEW_MQTT_DAEMON="$case_dir/daemon" DOORVIEW_MQTT_CONFIG="$case_dir/mqtt.conf" DOORVIEW_MQTT_PIDFILE="$case_dir/pid" DOORVIEW_MQTT_LOG="$case_dir/out.log" sh "$here/payload/etc/init.d/S97doorview-mqtt" start
    status=$?
    wait_for_lines "$LOG" 1 5 || true
    s97 stop > /dev/null 2>&1
    return $status
}
check 'a gateway in the configuration becomes the default route' s97_route 'host=192.0.2.20
gateway=192.0.2.1'
check 'the route is added with exactly that gateway' grep -qx 'route add default via 192.0.2.1' "$IP_LOG"
check 'no gateway means no route is added' s97_route 'host=192.0.2.20'
check 'nothing was added without a gateway' test "$(grep -c 'route add' "$IP_LOG")" = 0
check 'an invalid gateway is ignored' s97_route 'host=192.0.2.20
gateway=192.0.2.1; reboot'
check 'nothing was added for an invalid gateway' test "$(grep -c 'route add' "$IP_LOG")" = 0
check 'an existing default route is kept' s97_route 'host=192.0.2.20
gateway=192.0.2.1' 192.0.2.254
check 'nothing was added over an existing default route' test "$(grep -c 'route add' "$IP_LOG")" = 0
check 'a failing route command does not stop the daemon' s97_route 'host=192.0.2.20
gateway=192.0.2.1' '' 1
check 'the route command was attempted' grep -qx 'route add default via 192.0.2.1' "$IP_LOG"
check 'the daemon was started despite the failed route' test "$(wc -l < "$LOG" | tr -d ' ')" -ge 1

echo "passed=$passed failed=$failed"
[ "$failed" = 0 ]
