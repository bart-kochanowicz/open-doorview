#!/bin/sh
# Local fixture tests for the PIR sensitivity update. They never touch the camera; everything runs under a temporary
# root.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
old_daemon=$here/../stage10-early-daemon/payload/etc/doorview/doorview-mqtt
old_driver=$here/../stage6-wake-timer/payload/etc/doorview/syslink_net_irq.ko
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
    (cd "$1" && find . -type f | sort | while read -r file; do printf '%s %s %s\n' "$(digest "$file")" "$(mode_of "$file")" "$file"; done; find . -type d | sort)
}

old_of() {
    case "$1" in
        doorview-mqtt) echo "$old_daemon" ;;
        syslink_net_irq.ko) echo "$old_driver" ;;
    esac
}

expected_mode() {
    case "$1" in
        doorview-mqtt) echo 700 ;;
        *) echo 600 ;;
    esac
}

build_stage() {
    target=$1
    mkdir -p "$target"
    cp "$here/payload/etc/doorview/doorview-mqtt" "$here/payload/etc/doorview/syslink_net_irq.ko" "$target/"
    (cd "$target" && for name in doorview-mqtt syslink_net_irq.ko; do shasum -a 256 "$name"; done > SHA256SUMS)
}

build_root() {
    fixture=$1
    mkdir -p "$fixture/etc/doorview" "$fixture/etc/init.d"
    for hook in S39doorview S41doorview-network S95majestic S97doorview-mqtt; do
        printf '#!/bin/sh\n# %s\n' "$hook" > "$fixture/etc/init.d/$hook"
    done
    chmod 755 "$fixture/etc/init.d/"*
    printf 'host=192.0.2.20\npir_motion=1\npir_sensitivity=3\n' > "$fixture/etc/doorview/mqtt.conf"
    printf 'stage 7 daemon\n' > "$fixture/etc/doorview/doorview-mqtt.before-early"
    printf 'stage 2 hook\n' > "$fixture/etc/doorview/S96doorview-lcd.before-wake"
    printf 'syslink_poll\n' > "$fixture/etc/doorview/syslink_poll.ko"
    chmod 600 "$fixture/etc/doorview/"*
    cp "$old_daemon" "$fixture/etc/doorview/doorview-mqtt"
    chmod 700 "$fixture/etc/doorview/doorview-mqtt"
    cp "$old_driver" "$fixture/etc/doorview/syslink_net_irq.ko"
    chmod 600 "$fixture/etc/doorview/syslink_net_irq.ko"
}

mounts_ok="$work/mounts-ok"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\n' > "$mounts_ok"
mounts_masked="$work/mounts-masked"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\ntmpfs /etc/doorview tmpfs rw 0 0\n' > "$mounts_masked"

stage="$work/stage"
build_stage "$stage"

install_stage() {
    DOORVIEW_ROOT=$1 DOORVIEW_MOUNTS=${2:-$mounts_ok} DOORVIEW_FREE_KB=${3:-244} sh "$here/install.sh" "$stage"
}

untouched_state() {
    (cd "$1" && for name in etc/doorview/mqtt.conf etc/doorview/doorview-mqtt.before-early etc/doorview/S96doorview-lcd.before-wake etc/doorview/syslink_poll.ko etc/init.d/S39doorview etc/init.d/S41doorview-network etc/init.d/S95majestic etc/init.d/S97doorview-mqtt; do printf '%s %s %s\n' "$name" "$(digest "$name")" "$(mode_of "$name")"; done)
}

echo '== the files =='

check 'the old daemon is the file the installer pins' test "$(digest "$old_daemon")" = eebdb3b36b8532cbeeae2639069e83e1628b317aca1cfbbf80aea3a0762c7471
check 'the old driver is the file the installer pins' test "$(digest "$old_driver")" = 5a35ec4dd560094eaa55023ea49514b52c9e6d2364d50d485f035df0d504d2ec
check 'the new daemon is the build recorded in EXPECTED-BUILDS.txt' grep -q "^$(digest "$here/payload/etc/doorview/doorview-mqtt")  doorview-mqtt-stage12 " "$here/../EXPECTED-BUILDS.txt"
check 'the new driver is the build recorded in EXPECTED-BUILDS.txt' grep -q "^$(digest "$here/payload/etc/doorview/syslink_net_irq.ko")  syslink_net_irq.ko " "$here/../EXPECTED-BUILDS.txt"

echo '== install.sh =='

root="$work/root-success"
build_root "$root"
before=$(tree_state "$root")
untouched_before=$(untouched_state "$root")
check 'installs on the tested layout' install_stage "$root"
for name in doorview-mqtt syslink_net_irq.ko; do
    check "$name is replaced by the new file" cmp -s "$stage/$name" "$root/etc/doorview/$name"
    check "$name keeps its mode" test "$(mode_of "$root/etc/doorview/$name")" = "$(expected_mode "$name")"
    check "the previous $name is kept" cmp -s "$(old_of "$name")" "$root/etc/doorview/$name.before-high"
    check "the backup of $name is private" test "$(mode_of "$root/etc/doorview/$name.before-high")" = 600
done
check 'the configuration, the other hooks and the earlier backups are untouched' test "$untouched_before" = "$(untouched_state "$root")"
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
check_fails 'a second install is refused' install_stage "$root"
check 'rollback succeeds' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'rollback restores the exact original tree, modes included' test "$before" = "$(tree_state "$root")"
check_fails 'a second rollback is refused' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"

root="$work/root-output"
build_root "$root"
output=$(install_stage "$root" 2>&1)
check 'the install prints its marker' test "$output" = PIR_HIGH_INSTALLED
check 'the output names no configuration value' sh -c '! printf "%s" "$1" | grep -q 192.0.2.20' sh "$output"

root="$work/root-high-config"
build_root "$root"
install_stage "$root" > /dev/null 2>&1
sed 's/^pir_sensitivity=3$/pir_sensitivity=5/' "$root/etc/doorview/mqtt.conf" > "$root/etc/doorview/mqtt.conf.new"
mv "$root/etc/doorview/mqtt.conf.new" "$root/etc/doorview/mqtt.conf"
chmod 600 "$root/etc/doorview/mqtt.conf"
before=$(tree_state "$root")
check_fails 'rollback refuses while mqtt.conf asks for level 5 (the old daemon would not start)' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'refusal changes nothing (level 5 configured)' test "$before" = "$(tree_state "$root")"

for name in doorview-mqtt syslink_net_irq.ko; do
    root="$work/root-wrong-$name"
    build_root "$root"
    printf 'x' >> "$root/etc/doorview/$name"
    before=$(tree_state "$root")
    check_fails "refuses an unexpected installed $name" install_stage "$root"
    check "refusal changes nothing (unexpected $name)" test "$before" = "$(tree_state "$root")"
done

root="$work/root-space"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses when free space is too small' install_stage "$root" "$mounts_ok" 20
check 'refusal changes nothing (low space)' test "$before" = "$(tree_state "$root")"

root="$work/root-masked"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses when /etc/doorview is masked by another mount' install_stage "$root" "$mounts_masked"
check 'refusal changes nothing (masked mount)' test "$before" = "$(tree_state "$root")"

root="$work/root-existing"
build_root "$root"
printf 'x' > "$root/etc/doorview/syslink_net_irq.ko.before-high"
before=$(tree_state "$root")
check_fails 'refuses when a backup already exists' install_stage "$root"
check 'refusal changes nothing (existing backup)' test "$before" = "$(tree_state "$root")"

bad_stage="$work/stage-bad"
build_stage "$bad_stage"
printf 'x' >> "$bad_stage/syslink_net_irq.ko"
root="$work/root-bad-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage file that does not match SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=244 sh "$here/install.sh" "$bad_stage"
check 'refusal changes nothing (bad stage)' test "$before" = "$(tree_state "$root")"

short_stage="$work/stage-short-manifest"
build_stage "$short_stage"
printf 'x' >> "$short_stage/doorview-mqtt"
grep -v ' doorview-mqtt$' "$short_stage/SHA256SUMS" > "$short_stage/SHA256SUMS.new"
mv "$short_stage/SHA256SUMS.new" "$short_stage/SHA256SUMS"
root="$work/root-short-manifest"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a SHA256SUMS that omits a payload file' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=244 sh "$here/install.sh" "$short_stage"
check 'refusal changes nothing (short manifest)' test "$before" = "$(tree_state "$root")"

shim="$work/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' > "$shim/sync"
chmod 755 "$shim/sync"
root="$work/root-rollback"
build_root "$root"
before=$(tree_state "$root")
check_fails 'a failure after both files are in place fails the install' env PATH="$shim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=244 sh "$here/install.sh" "$stage"
check 'failed install rolls back to the exact original tree, modes included' test "$before" = "$(tree_state "$root")"

real_mktemp=$(command -v mktemp)
mkshim="$work/mktemp-shim"
mkdir -p "$mkshim"
cp "$shim/sync" "$mkshim/sync"
cat > "$mkshim/mktemp" << SHIM
#!/bin/sh
count=\$(cat "$work/mktemp-count" 2> /dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "$work/mktemp-count"
[ "\$count" -gt 1 ] && exit 1
exec "$real_mktemp" "\$@"
SHIM
chmod 755 "$mkshim/mktemp"
rm -f "$work/mktemp-count"
root="$work/root-restore-fails"
build_root "$root"
check_fails 'an install whose restore also fails reports failure' env PATH="$mkshim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=244 sh "$here/install.sh" "$stage"
check 'the backup of the daemon is kept when the restore failed' cmp -s "$old_daemon" "$root/etc/doorview/doorview-mqtt.before-high"
check 'the backup of the driver is kept when the restore failed' cmp -s "$old_driver" "$root/etc/doorview/syslink_net_irq.ko.before-high"

echo '== rollback.sh =='

root="$work/root-rb-damaged"
build_root "$root"
install_stage "$root" > /dev/null 2>&1
printf 'x' >> "$root/etc/doorview/syslink_net_irq.ko.before-high"
before=$(tree_state "$root")
check_fails 'rollback refuses a damaged backup' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'refusal changes nothing (damaged backup)' test "$before" = "$(tree_state "$root")"

root="$work/root-rb-missing"
build_root "$root"
before=$(tree_state "$root")
check_fails 'rollback without an install is refused' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'refusal changes nothing (nothing to roll back)' test "$before" = "$(tree_state "$root")"

echo
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
