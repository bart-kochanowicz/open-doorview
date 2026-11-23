#!/bin/sh
# Local fixture tests for the fast-boot update. They never touch the camera; everything runs under a temporary root.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
stock_rcs=$here/tests/fixtures/rcS.stock
old_s39=$here/../stage1-wifi/payload/etc/init.d/S39doorview
old_s41=$here/../stage2-lcd/payload/etc/init.d/S41doorview-network
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
    cp "$here/payload/etc/init.d/rcS" "$here/payload/etc/init.d/S39doorview" "$here/payload/etc/init.d/S41doorview-network" "$target/"
    (cd "$target" && for name in rcS S39doorview S41doorview-network; do shasum -a 256 "$name"; done > SHA256SUMS)
}

build_root() {
    fixture=$1
    mkdir -p "$fixture/etc/doorview" "$fixture/etc/init.d"
    cp "$stock_rcs" "$fixture/etc/init.d/rcS"
    cp "$old_s39" "$fixture/etc/init.d/S39doorview"
    cp "$old_s41" "$fixture/etc/init.d/S41doorview-network"
    for hook in S95majestic S96doorview-lcd S97doorview-mqtt; do
        printf '#!/bin/sh\n# %s\n' "$hook" > "$fixture/etc/init.d/$hook"
    done
    chmod 755 "$fixture/etc/init.d/"*
    printf '%s\n' "$(printf 'ab%.0s' $(seq 1 64))" > "$fixture/etc/doorview/station.hex"
    printf 'daemon\n' > "$fixture/etc/doorview/doorview-mqtt"
    printf 'host=192.0.2.20\n' > "$fixture/etc/doorview/mqtt.conf"
    printf 'old backup\n' > "$fixture/etc/doorview/syslink_net_irq.ko.before-sleep"
    chmod 600 "$fixture/etc/doorview/"*
}

mounts_ok="$work/mounts-ok"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\n' > "$mounts_ok"
mounts_masked="$work/mounts-masked"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\ntmpfs /etc/init.d tmpfs rw 0 0\n' > "$mounts_masked"

stage="$work/stage"
build_stage "$stage"

install_stage() {
    DOORVIEW_ROOT=$1 DOORVIEW_MOUNTS=${2:-$mounts_ok} DOORVIEW_FREE_KB=${3:-288} sh "$here/install.sh" "$stage"
}

# Every file that the installer must not touch, as one comparable string.
untouched_state() {
    (cd "$1/etc" && for name in doorview/station.hex doorview/doorview-mqtt doorview/mqtt.conf doorview/syslink_net_irq.ko.before-sleep init.d/S95majestic init.d/S96doorview-lcd init.d/S97doorview-mqtt; do printf '%s %s %s\n' "$name" "$(digest "$name")" "$(mode_of "$name")"; done)
}

# The script that each name replaces.
old_of() {
    case "$1" in
        rcS) echo "$stock_rcs" ;;
        S39doorview) echo "$old_s39" ;;
        *) echo "$old_s41" ;;
    esac
}

echo '== the scripts =='

check 'the stock rcS fixture is the file the installer pins' test "$(digest "$stock_rcs")" = 1ca35513c874f3e89ad790b7841c07db9eef6be7c1f0469596de82b4fa87fe67
check 'the new rcS, S39 and S41 are valid shell' sh -c "sh -n '$here/payload/etc/init.d/rcS' && sh -n '$here/payload/etc/init.d/S39doorview' && sh -n '$here/payload/etc/init.d/S41doorview-network'"
check 'the new rcS keeps the failsafe branch of the stock one' grep -q 'grep -qw failsafe /proc/cmdline' "$here/payload/etc/init.d/rcS"
check 'the new rcS starts the daemon after the Wi-Fi link (it needs the default route)' sh -c "awk '/^start S41doorview-network/{n=NR} /^start S97doorview-mqtt/{m=NR} END{exit !(n && m && n < m)}' '$here/payload/etc/init.d/rcS'"
check 'the new rcS waits for the camera stack before the daemon' sh -c "awk '/^wait /{w=NR} /^start S97doorview-mqtt/{m=NR} END{exit !(w && m && w < m)}' '$here/payload/etc/init.d/rcS'"
check 'the new rcS runs nothing it was not told to (no loop over S??*)' sh -c "! grep -q 'S??' '$here/payload/etc/init.d/rcS'"
for skipped in S01seedrng S01syslogd S02fakehwclock S02klogd S35modules S38mdev S49ntpd S60crond S98vtun S98wireguard; do
    check "the new rcS does not start $skipped" sh -c "! grep -q '$skipped' '$here/payload/etc/init.d/rcS'"
done
check 'S39doorview no longer sleeps a fixed second' sh -c "! grep -q '^        sleep 1\$' '$here/payload/etc/init.d/S39doorview'"
check 'S41doorview-network polls every 0.1 s' grep -q 'sleep 0.1' "$here/payload/etc/init.d/S41doorview-network"

echo '== install.sh =='

root="$work/root-success"
build_root "$root"
before=$(tree_state "$root")
untouched_before=$(untouched_state "$root")
check 'installs on the tested layout' install_stage "$root"
for name in rcS S39doorview S41doorview-network; do
    check "$name is replaced by the new script" cmp -s "$stage/$name" "$root/etc/init.d/$name"
    check "$name is executable" test -x "$root/etc/init.d/$name"
    check "the previous $name is kept in /etc/doorview" cmp -s "$(old_of "$name")" "$root/etc/doorview/$name.before-fast"
    check "no copy of $name is left in /etc/init.d where the stock rcS would run it" test "$(ls "$root/etc/init.d" | grep -c "^$name\\.")" = 0
done
check 'the backups are private' test "$(mode_of "$root/etc/doorview/rcS.before-fast")$(mode_of "$root/etc/doorview/S39doorview.before-fast")$(mode_of "$root/etc/doorview/S41doorview-network.before-fast")" = 600600600
check 'configuration, daemon, station and the other hooks are untouched' test "$untouched_before" = "$(untouched_state "$root")"
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
check_fails 'a second install is refused' install_stage "$root"
check 'rollback succeeds' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'rollback restores the exact original tree' test "$before" = "$(tree_state "$root")"
check 'rollback writes the stock rcS back as a file (it must not delete it)' test -f "$root/etc/init.d/rcS"
check_fails 'a second rollback is refused' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"

for name in rcS S39doorview S41doorview-network; do
    root="$work/root-wrong-$name"
    build_root "$root"
    printf 'x' >> "$root/etc/init.d/$name"
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
check_fails 'refuses when /etc/init.d is masked by another mount' install_stage "$root" "$mounts_masked"
check 'refusal changes nothing (masked mount)' test "$before" = "$(tree_state "$root")"

root="$work/root-existing"
build_root "$root"
printf 'x' > "$root/etc/doorview/S41doorview-network.before-fast"
before=$(tree_state "$root")
check_fails 'refuses when a backup already exists' install_stage "$root"
check 'refusal changes nothing (existing backup)' test "$before" = "$(tree_state "$root")"

bad_stage="$work/stage-bad"
build_stage "$bad_stage"
printf 'x' >> "$bad_stage/rcS"
root="$work/root-bad-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage file that does not match SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$bad_stage"
check 'refusal changes nothing (bad stage)' test "$before" = "$(tree_state "$root")"

# A manifest that does not cover every installed file must not let an unverified file through.
empty_stage="$work/stage-empty-manifest"
build_stage "$empty_stage"
printf 'x' >> "$empty_stage/rcS"
: > "$empty_stage/SHA256SUMS"
root="$work/root-empty-manifest"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses an empty SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$empty_stage"
check 'refusal changes nothing (empty manifest)' test "$before" = "$(tree_state "$root")"
short_stage="$work/stage-short-manifest"
build_stage "$short_stage"
grep -v ' S39doorview$' "$short_stage/SHA256SUMS" > "$short_stage/SHA256SUMS.new"
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
check_fails 'a failure after all three scripts are in place fails the install' env PATH="$shim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
check 'failed install rolls back to the exact original tree' test "$before" = "$(tree_state "$root")"

# If restoring the old scripts also fails, the backups are the only copies left and must be kept.
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
check 'the backup of the stock rcS is kept when the restore failed' cmp -s "$stock_rcs" "$root/etc/doorview/rcS.before-fast"
check 'the backup of S39doorview is kept when the restore failed' cmp -s "$old_s39" "$root/etc/doorview/S39doorview.before-fast"
check 'the backup of S41doorview-network is kept when the restore failed' cmp -s "$old_s41" "$root/etc/doorview/S41doorview-network.before-fast"
check 'a failed restore does not write a stray copy into the working directory' test ! -e "./rcS.before-fast"

echo '== rollback.sh =='

root="$work/root-rb-damaged"
build_root "$root"
install_stage "$root" > /dev/null 2>&1
printf 'x' >> "$root/etc/doorview/S41doorview-network.before-fast"
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
