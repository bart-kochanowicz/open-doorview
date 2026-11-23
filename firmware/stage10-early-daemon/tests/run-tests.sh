#!/bin/sh
# Local fixture tests for the early daemon update. They never touch the camera; everything runs under a temporary root.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
old_rcs=$here/../stage9-lean/payload/etc/init.d/rcS
old_daemon=$here/../stage7-pir-motion/payload/etc/doorview/doorview-mqtt
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

# Where each name lives on the camera, and the file it replaces.
path_of() {
    case "$1" in
        rcS) echo etc/init.d/rcS ;;
        doorview-mqtt) echo etc/doorview/doorview-mqtt ;;
    esac
}
old_of() {
    case "$1" in
        rcS) echo "$old_rcs" ;;
        doorview-mqtt) echo "$old_daemon" ;;
    esac
}

expected_mode() {
    case "$1" in
        rcS) echo 755 ;;
        *) echo 700 ;;
    esac
}

build_stage() {
    target=$1
    mkdir -p "$target"
    cp "$here/payload/etc/init.d/rcS" "$here/payload/etc/doorview/doorview-mqtt" "$target/"
    (cd "$target" && for name in rcS doorview-mqtt; do shasum -a 256 "$name"; done > SHA256SUMS)
}

build_root() {
    fixture=$1
    mkdir -p "$fixture/etc/doorview" "$fixture/etc/init.d"
    cp "$old_rcs" "$fixture/etc/init.d/rcS"
    for hook in S39doorview S41doorview-network S95majestic S97doorview-mqtt; do
        printf '#!/bin/sh\n# %s\n' "$hook" > "$fixture/etc/init.d/$hook"
    done
    chmod 755 "$fixture/etc/init.d/"*
    printf 'stage 8 rcS\n' > "$fixture/etc/doorview/rcS.before-lean"
    printf 'host=192.0.2.20\n' > "$fixture/etc/doorview/mqtt.conf"
    printf 'stage 6 daemon\n' > "$fixture/etc/doorview/doorview-mqtt.before-pir"
    chmod 600 "$fixture/etc/doorview/"*
    cp "$old_daemon" "$fixture/etc/doorview/doorview-mqtt"
    chmod 700 "$fixture/etc/doorview/doorview-mqtt"
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

untouched_state() {
    (cd "$1" && for name in etc/doorview/rcS.before-lean etc/doorview/mqtt.conf etc/doorview/doorview-mqtt.before-pir etc/init.d/S39doorview etc/init.d/S41doorview-network etc/init.d/S95majestic etc/init.d/S97doorview-mqtt; do printf '%s %s %s\n' "$name" "$(digest "$name")" "$(mode_of "$name")"; done)
}

echo '== the files =='

check 'the new rcS is valid shell' sh -n "$here/payload/etc/init.d/rcS"
check 'the daemon starts right after the Wi-Fi link, before the wait for the camera stack' sh -c "awk '/^start S41doorview-network/{a=NR} /^start S97doorview-mqtt/{b=NR} /^wait /{c=NR} END{exit !(a && b && c && a < b && b < c)}' '$here/payload/etc/init.d/rcS'"
check 'the loopback is still brought up before the daemon' sh -c "awk '/^ifup lo/{a=NR} /^start S97doorview-mqtt/{b=NR} END{exit !(a && b && a < b)}' '$here/payload/etc/init.d/rcS'"
check 'the stock network start is no longer run' sh -c "! grep -q 'S40network' '$here/payload/etc/init.d/rcS'"
check 'the new rcS keeps the failsafe branch' grep -q 'grep -qw failsafe /proc/cmdline' "$here/payload/etc/init.d/rcS"

echo '== install.sh =='

root="$work/root-success"
build_root "$root"
before=$(tree_state "$root")
untouched_before=$(untouched_state "$root")
check 'installs on the tested layout' install_stage "$root"
for name in rcS doorview-mqtt; do
    check "$name is replaced by the new file" cmp -s "$stage/$name" "$root/$(path_of "$name")"
    check "$name keeps its mode" test "$(mode_of "$root/$(path_of "$name")")" = "$(expected_mode "$name")"
    check "the previous $name is kept in /etc/doorview" cmp -s "$(old_of "$name")" "$root/etc/doorview/$name.before-early"
    check "the backup of $name is private" test "$(mode_of "$root/etc/doorview/$name.before-early")" = 600
done
check 'no backup is left in /etc/init.d, where the stock rcS would run it' test "$(ls "$root/etc/init.d" | grep -c 'before-lean')" = 0
check 'the other hooks, the configuration and the earlier backups are untouched' test "$untouched_before" = "$(untouched_state "$root")"
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
check_fails 'a second install is refused' install_stage "$root"
check 'rollback succeeds' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'rollback restores the exact original tree' test "$before" = "$(tree_state "$root")"
check 'rollback gives both files their modes back (755 rcS, 700 daemon)' test "$(mode_of "$root/etc/init.d/rcS")$(mode_of "$root/etc/doorview/doorview-mqtt")" = 755700
check_fails 'a second rollback is refused' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"

for name in rcS doorview-mqtt; do
    root="$work/root-wrong-$name"
    build_root "$root"
    printf 'x' >> "$root/$(path_of "$name")"
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
printf 'x' > "$root/etc/doorview/doorview-mqtt.before-early"
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

short_stage="$work/stage-short-manifest"
build_stage "$short_stage"
printf 'x' >> "$short_stage/doorview-mqtt"
grep -v ' doorview-mqtt$' "$short_stage/SHA256SUMS" > "$short_stage/SHA256SUMS.new"
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
check_fails 'a failure after both files are in place fails the install' env PATH="$shim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
check 'failed install rolls back to the exact original tree' test "$before" = "$(tree_state "$root")"

real_mktemp=$(command -v mktemp)
mkshim="$work/mktemp-shim"
mkdir -p "$mkshim"
cp "$shim/sync" "$mkshim/sync"
cat > "$mkshim/mktemp" << SHIM
#!/bin/sh
count=\$(cat "$work/mktemp-count" 2> /dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "$work/mktemp-count"
[ "\$count" -gt 2 ] && exit 1
exec "$real_mktemp" "\$@"
SHIM
chmod 755 "$mkshim/mktemp"
rm -f "$work/mktemp-count"
root="$work/root-restore-fails"
build_root "$root"
check_fails 'an install whose restore also fails reports failure' env PATH="$mkshim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
check 'the backup of rcS is kept when the restore failed' cmp -s "$old_rcs" "$root/etc/doorview/rcS.before-early"
check 'the backup of the daemon is kept when the restore failed' cmp -s "$old_daemon" "$root/etc/doorview/doorview-mqtt.before-early"

echo '== rollback.sh =='

root="$work/root-rb-damaged"
build_root "$root"
install_stage "$root" > /dev/null 2>&1
printf 'x' >> "$root/etc/doorview/doorview-mqtt.before-early"
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
