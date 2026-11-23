#!/bin/sh
# Local fixture tests for the sleep candidate. They never touch the camera; everything runs under a temporary root.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
old_poll=$here/../stage1-wifi/payload/etc/doorview/syslink_poll.ko
old_net=$here/../stage3-mqtt/payload/etc/doorview/syslink_net_irq.ko
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
    cp "$here/payload/etc/doorview/syslink_poll.ko" "$here/payload/etc/doorview/syslink_net_irq.ko" "$target/"
    (cd "$target" && for name in syslink_poll.ko syslink_net_irq.ko; do shasum -a 256 "$name"; done > SHA256SUMS)
}

build_root() {
    fixture=$1
    mkdir -p "$fixture/etc/doorview" "$fixture/etc/init.d"
    cp "$old_poll" "$fixture/etc/doorview/syslink_poll.ko"
    cp "$old_net" "$fixture/etc/doorview/syslink_net_irq.ko"
    printf '%s\n' "$(printf 'ab%.0s' $(seq 1 64))" > "$fixture/etc/doorview/station.hex"
    printf '192.0.2.10/24\n' > "$fixture/etc/doorview/address"
    # Stage 3 keeps the stage 2 driver under this name; this stage must leave it alone.
    cp "$here/../stage2-lcd/payload/etc/doorview/syslink_net_irq.ko" "$fixture/etc/doorview/syslink_net_irq.ko.previous"
    printf 'bg\n' > "$fixture/etc/doorview/syslink_bg.ko"
    printf 'net\n' > "$fixture/etc/doorview/syslink_net.ko"
    printf 'daemon\n' > "$fixture/etc/doorview/doorview-mqtt"
    printf 'host=192.0.2.20\n' > "$fixture/etc/doorview/mqtt.conf"
    for hook in S39doorview S41doorview-network S96doorview-lcd S97doorview-mqtt; do
        printf '#!/bin/sh\n# %s\n' "$hook" > "$fixture/etc/init.d/$hook"
        chmod 755 "$fixture/etc/init.d/$hook"
    done
    chmod 600 "$fixture/etc/doorview/syslink_poll.ko" "$fixture/etc/doorview/syslink_net_irq.ko" "$fixture/etc/doorview/station.hex"
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
    (cd "$1/etc" && for name in doorview/syslink_net_irq.ko.previous doorview/station.hex doorview/address doorview/syslink_bg.ko doorview/syslink_net.ko doorview/doorview-mqtt doorview/mqtt.conf init.d/S39doorview init.d/S41doorview-network init.d/S96doorview-lcd init.d/S97doorview-mqtt; do printf '%s %s %s\n' "$name" "$(digest "$name")" "$(mode_of "$name")"; done)
}

echo '== install.sh =='

root="$work/root-success"
build_root "$root"
before=$(tree_state "$root")
untouched_before=$(untouched_state "$root")
check 'installs on the tested layout' install_stage "$root"
check 'syslink_poll.ko is replaced by the new build' cmp -s "$stage/syslink_poll.ko" "$root/etc/doorview/syslink_poll.ko"
check 'syslink_net_irq.ko is replaced by the new build' cmp -s "$stage/syslink_net_irq.ko" "$root/etc/doorview/syslink_net_irq.ko"
check 'the previous poll driver is kept for rollback' cmp -s "$old_poll" "$root/etc/doorview/syslink_poll.ko.before-sleep"
check 'the previous network driver is kept for rollback' cmp -s "$old_net" "$root/etc/doorview/syslink_net_irq.ko.before-sleep"
check 'the new poll driver is private' test "$(mode_of "$root/etc/doorview/syslink_poll.ko")" = 600
check 'the new network driver is private' test "$(mode_of "$root/etc/doorview/syslink_net_irq.ko")" = 600
check 'the backups are private' test "$(mode_of "$root/etc/doorview/syslink_poll.ko.before-sleep")$(mode_of "$root/etc/doorview/syslink_net_irq.ko.before-sleep")" = 600600
check 'hooks, station, daemon, configuration and the other drivers are untouched' test "$untouched_before" = "$(untouched_state "$root")"
check 'no boot hook is added' test "$(ls "$root/etc/init.d" | tr '\n' ' ')" = 'S39doorview S41doorview-network S96doorview-lcd S97doorview-mqtt '
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
check_fails 'a second install is refused' install_stage "$root"
check 'rollback succeeds' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'rollback restores the exact original tree' test "$before" = "$(tree_state "$root")"
check_fails 'a second rollback is refused' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"

root="$work/root-poll"
build_root "$root"
printf 'x' >> "$root/etc/doorview/syslink_poll.ko"
before=$(tree_state "$root")
check_fails 'refuses an unexpected installed poll driver' install_stage "$root"
check 'refusal changes nothing (unexpected poll driver)' test "$before" = "$(tree_state "$root")"

root="$work/root-net"
build_root "$root"
printf 'x' >> "$root/etc/doorview/syslink_net_irq.ko"
before=$(tree_state "$root")
check_fails 'refuses an unexpected installed network driver' install_stage "$root"
check 'refusal changes nothing (unexpected network driver)' test "$before" = "$(tree_state "$root")"

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
printf 'x' > "$root/etc/doorview/syslink_poll.ko.before-sleep"
before=$(tree_state "$root")
check_fails 'refuses when a backup already exists' install_stage "$root"
check 'refusal changes nothing (existing backup)' test "$before" = "$(tree_state "$root")"

bad_stage="$work/stage-bad"
build_stage "$bad_stage"
printf 'x' >> "$bad_stage/syslink_net_irq.ko"
root="$work/root-bad-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage file that does not match SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$bad_stage"
check 'refusal changes nothing (bad stage)' test "$before" = "$(tree_state "$root")"

# A manifest that does not cover every installed file must not let an unverified file through.
empty_stage="$work/stage-empty-manifest"
build_stage "$empty_stage"
printf 'x' >> "$empty_stage/syslink_poll.ko"
: > "$empty_stage/SHA256SUMS"
root="$work/root-empty-manifest"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses an empty SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$empty_stage"
check 'refusal changes nothing (empty manifest)' test "$before" = "$(tree_state "$root")"
short_stage="$work/stage-short-manifest"
build_stage "$short_stage"
grep -v ' syslink_poll.ko$' "$short_stage/SHA256SUMS" > "$short_stage/SHA256SUMS.new"
mv "$short_stage/SHA256SUMS.new" "$short_stage/SHA256SUMS"
root="$work/root-short-manifest"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a SHA256SUMS that omits a payload file' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$short_stage"
check 'refusal changes nothing (short manifest)' test "$before" = "$(tree_state "$root")"

shim="$work/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' > "$shim/sync"
chmod 755 "$shim/sync"
root="$work/root-rollback"
build_root "$root"
before=$(tree_state "$root")
check_fails 'a failure after both drivers are in place fails the install' env PATH="$shim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
check 'failed install rolls back to the exact original tree' test "$before" = "$(tree_state "$root")"

# If restoring the old drivers also fails, the backups are the only copies left and must be kept.
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
check 'the backup of the old poll driver is kept when the restore failed' cmp -s "$old_poll" "$root/etc/doorview/syslink_poll.ko.before-sleep"
check 'the backup of the old network driver is kept when the restore failed' cmp -s "$old_net" "$root/etc/doorview/syslink_net_irq.ko.before-sleep"
check 'a failed restore does not write a stray copy into the working directory' test ! -e "./syslink_poll.ko.before-sleep"

echo '== rollback.sh =='

root="$work/root-rb-damaged"
build_root "$root"
install_stage "$root" > /dev/null 2>&1
printf 'x' >> "$root/etc/doorview/syslink_net_irq.ko.before-sleep"
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
