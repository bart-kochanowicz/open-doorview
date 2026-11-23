#!/bin/sh
# Local fixture tests for the PIR daemon update. They never touch the camera; everything runs under a temporary root.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
old_daemon=$here/../stage6-wake-timer/payload/etc/doorview/doorview-mqtt
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
    cp "$here/payload/etc/doorview/doorview-mqtt" "$target/"
    (cd "$target" && shasum -a 256 doorview-mqtt > SHA256SUMS)
}

build_root() {
    fixture=$1
    mkdir -p "$fixture/etc/doorview" "$fixture/etc/init.d"
    cp "$old_daemon" "$fixture/etc/doorview/doorview-mqtt"
    chmod 700 "$fixture/etc/doorview/doorview-mqtt"
    printf 'host=192.0.2.20\npassword=not-a-real-secret\n' > "$fixture/etc/doorview/mqtt.conf"
    chmod 600 "$fixture/etc/doorview/mqtt.conf"
    printf 'driver\n' > "$fixture/etc/doorview/syslink_net_irq.ko"
    cp "$here/../stage3-mqtt/payload/etc/doorview/doorview-mqtt" "$fixture/etc/doorview/doorview-mqtt.before-sleep"
    cp "$here/../stage5-sleep-daemon/payload/etc/doorview/doorview-mqtt" "$fixture/etc/doorview/doorview-mqtt.before-timer"
    printf 'driver.previous\n' > "$fixture/etc/doorview/syslink_net_irq.ko.previous"
    printf '#!/bin/sh\n# S97\n' > "$fixture/etc/init.d/S97doorview-mqtt"
    chmod 755 "$fixture/etc/init.d/S97doorview-mqtt"
}

mounts_ok="$work/mounts-ok"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\n' > "$mounts_ok"
mounts_masked="$work/mounts-masked"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\ntmpfs /etc/doorview tmpfs rw 0 0\n' > "$mounts_masked"

stage="$work/stage"
build_stage "$stage"

install_stage() {
    DOORVIEW_ROOT=$1 DOORVIEW_MOUNTS=${2:-$mounts_ok} DOORVIEW_FREE_KB=${3:-288} sh "$here/install.sh" "$stage"
}

# Every file that the installer must not touch, as one comparable string.
untouched_state() {
    (cd "$1/etc" && for name in doorview/doorview-mqtt.before-sleep doorview/doorview-mqtt.before-timer doorview/mqtt.conf doorview/syslink_net_irq.ko doorview/syslink_net_irq.ko.previous init.d/S97doorview-mqtt; do printf '%s %s %s\n' "$name" "$(digest "$name")" "$(mode_of "$name")"; done)
}

echo '== install.sh =='

root="$work/root-success"
build_root "$root"
before=$(tree_state "$root")
untouched_before=$(untouched_state "$root")
check 'installs on the tested layout' install_stage "$root"
check 'the daemon is replaced by the new build' cmp -s "$stage/doorview-mqtt" "$root/etc/doorview/doorview-mqtt"
check 'the previous daemon is kept for rollback' cmp -s "$old_daemon" "$root/etc/doorview/doorview-mqtt.before-pir"
check 'the daemon is executable only by its owner' test "$(mode_of "$root/etc/doorview/doorview-mqtt")" = 700
check 'the backup is executable only by its owner' test "$(mode_of "$root/etc/doorview/doorview-mqtt.before-pir")" = 700
check 'configuration, drivers and the boot hook are untouched' test "$untouched_before" = "$(untouched_state "$root")"
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
check_fails 'a second install is refused' install_stage "$root"
check 'rollback succeeds' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'rollback restores the exact original tree' test "$before" = "$(tree_state "$root")"
check_fails 'a second rollback is refused' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"

root="$work/root-daemon"
build_root "$root"
printf 'x' >> "$root/etc/doorview/doorview-mqtt"
before=$(tree_state "$root")
check_fails 'refuses an unexpected installed daemon' install_stage "$root"
check 'refusal changes nothing (unexpected daemon)' test "$before" = "$(tree_state "$root")"

root="$work/root-nodaemon"
build_root "$root"
rm -f "$root/etc/doorview/doorview-mqtt"
before=$(tree_state "$root")
check_fails 'refuses when there is no daemon to replace' install_stage "$root"
check 'refusal changes nothing (no daemon)' test "$before" = "$(tree_state "$root")"

root="$work/root-space"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses when free space is too small' install_stage "$root" "$mounts_ok" 60
check 'refusal changes nothing (low space)' test "$before" = "$(tree_state "$root")"

root="$work/root-masked"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses when /etc/doorview is masked by another mount' install_stage "$root" "$mounts_masked"
check 'refusal changes nothing (masked mount)' test "$before" = "$(tree_state "$root")"

root="$work/root-existing"
build_root "$root"
printf 'x' > "$root/etc/doorview/doorview-mqtt.before-pir"
before=$(tree_state "$root")
check_fails 'refuses when a backup already exists' install_stage "$root"
check 'refusal changes nothing (existing backup)' test "$before" = "$(tree_state "$root")"

bad_stage="$work/stage-bad"
build_stage "$bad_stage"
printf 'x' >> "$bad_stage/doorview-mqtt"
root="$work/root-bad-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage file that does not match SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$bad_stage"
check 'refusal changes nothing (bad stage)' test "$before" = "$(tree_state "$root")"

# A manifest that does not cover the installed file must not let an unverified file through.
empty_stage="$work/stage-empty-manifest"
build_stage "$empty_stage"
printf 'x' >> "$empty_stage/doorview-mqtt"
: > "$empty_stage/SHA256SUMS"
root="$work/root-empty-manifest"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses an empty SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$empty_stage"
check 'refusal changes nothing (empty manifest)' test "$before" = "$(tree_state "$root")"

shim="$work/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' > "$shim/sync"
chmod 755 "$shim/sync"
root="$work/root-rollback"
build_root "$root"
before=$(tree_state "$root")
check_fails 'a failure after the daemon is in place fails the install' env PATH="$shim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
check 'failed install rolls back to the exact original tree' test "$before" = "$(tree_state "$root")"

# If restoring the old daemon also fails, the backup is the only copy left and must be kept.
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
check_fails 'an install whose restore also fails reports failure' env PATH="$mkshim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
check 'the backup of the old daemon is kept when the restore failed' cmp -s "$old_daemon" "$root/etc/doorview/doorview-mqtt.before-pir"
check 'a failed restore does not write a stray copy into the working directory' test ! -e "./doorview-mqtt.before-pir"

echo '== rollback.sh =='

root="$work/root-rb-damaged"
build_root "$root"
install_stage "$root" > /dev/null 2>&1
printf 'x' >> "$root/etc/doorview/doorview-mqtt.before-pir"
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
