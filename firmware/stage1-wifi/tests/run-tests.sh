#!/bin/sh
# Local fixture tests for the Wi-Fi base stage. They never touch a camera; everything runs under a temporary root.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
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

stage_names='syslink_poll.ko syslink_bg.ko syslink_net.ko S39doorview S41doorview-network'

build_stage() {
    target=$1
    mkdir -p "$target"
    for name in syslink_poll.ko syslink_bg.ko syslink_net.ko; do
        cp "$here/payload/etc/doorview/$name" "$target/"
    done
    for name in S39doorview S41doorview-network; do
        cp "$here/payload/etc/init.d/$name" "$target/"
    done
    (cd "$target" && for name in $stage_names; do shasum -a 256 "$name"; done > SHA256SUMS)
}

# A fresh OpenIPC overlay: /etc/init.d exists, /etc/doorview does not.
build_root() {
    fixture=$1
    mkdir -p "$fixture/etc/init.d"
    printf '#!/bin/sh\n' > "$fixture/etc/init.d/S95majestic"
    printf 'root:x:0:0\n' > "$fixture/etc/passwd"
}

mounts_ok="$work/mounts-ok"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\n' > "$mounts_ok"
mounts_masked="$work/mounts-masked"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock5 /overlay jffs2 rw,relatime 0 0\ntmpfs /etc/doorview tmpfs rw 0 0\n' > "$mounts_masked"
mounts_wrong="$work/mounts-wrong"
printf 'overlay / overlay rw,relatime 0 0\n/dev/mtdblock4 /overlay jffs2 rw,relatime 0 0\n' > "$mounts_wrong"

stage="$work/stage"
build_stage "$stage"

install() {
    DOORVIEW_ROOT=$1 DOORVIEW_MOUNTS=${2:-$mounts_ok} DOORVIEW_FREE_KB=${3:-400} sh "$here/install.sh" "$stage"
}

echo '== install.sh =='

root="$work/root-success"
build_root "$root"
before=$(tree_state "$root")
check 'installs on a fresh overlay' install "$root"
for name in syslink_poll.ko syslink_bg.ko syslink_net.ko; do
    check "$name installed" cmp -s "$stage/$name" "$root/etc/doorview/$name"
done
for name in S39doorview S41doorview-network; do
    check "$name installed" cmp -s "$stage/$name" "$root/etc/init.d/$name"
done
check 'modules are private (mode 600)' test "$(mode_of "$root/etc/doorview/syslink_net.ko")" = 600
check 'boot hooks are executable (mode 755)' test "$(mode_of "$root/etc/init.d/S41doorview-network")" = 755
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
check 'unrelated files untouched' test "$(cat "$root/etc/passwd")" = 'root:x:0:0'
check_fails 'second install is refused' install "$root"
check 'rollback succeeds' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh" "$stage"
check 'rollback leaves only an empty /etc/doorview behind' test -d "$root/etc/doorview" -a -z "$(ls -A "$root/etc/doorview")"
rmdir "$root/etc/doorview"
check 'rollback restores the exact original tree' test "$before" = "$(tree_state "$root")"

root="$work/root-existing-dir"
build_root "$root"
mkdir -p "$root/etc/doorview"
before=$(tree_state "$root")
check 'installs when /etc/doorview already exists' install "$root"
check 'rollback keeps a pre-existing /etc/doorview' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh" "$stage"
check 'rollback restores the tree with the pre-existing directory' test "$before" = "$(tree_state "$root")"

for target in etc/doorview/syslink_poll.ko etc/doorview/syslink_bg.ko etc/doorview/syslink_net.ko etc/init.d/S39doorview etc/init.d/S41doorview-network; do
    root="$work/root-existing-$(basename "$target")"
    build_root "$root"
    mkdir -p "$root/etc/doorview"
    printf 'mine\n' > "$root/$target"
    before=$(tree_state "$root")
    check_fails "refuses when $(basename "$target") already exists" install "$root"
    check "refusal changes nothing ($(basename "$target"))" test "$before" = "$(tree_state "$root")"
done

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

root="$work/root-wrong-mtd"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses when the overlay is not mtdblock5' install "$root" "$mounts_wrong"
check 'refusal changes nothing (wrong partition)' test "$before" = "$(tree_state "$root")"

bad_stage="$work/stage-bad"
build_stage "$bad_stage"
printf 'x' >> "$bad_stage/syslink_net.ko"
root="$work/root-bad-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage file that does not match SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=400 sh "$here/install.sh" "$bad_stage"
check 'refusal changes nothing (bad stage)' test "$before" = "$(tree_state "$root")"

short_stage="$work/stage-short"
build_stage "$short_stage"
grep -v ' S39doorview$' "$short_stage/SHA256SUMS" > "$short_stage/SHA256SUMS.new"
mv "$short_stage/SHA256SUMS.new" "$short_stage/SHA256SUMS"
root="$work/root-short-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage whose SHA256SUMS omits a file' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=400 sh "$here/install.sh" "$short_stage"
check 'refusal changes nothing (short SHA256SUMS)' test "$before" = "$(tree_state "$root")"

missing_stage="$work/stage-missing"
build_stage "$missing_stage"
rm "$missing_stage/syslink_bg.ko"
root="$work/root-missing-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage with a missing file' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=400 sh "$here/install.sh" "$missing_stage"
check 'refusal changes nothing (missing stage file)' test "$before" = "$(tree_state "$root")"

shim="$work/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' > "$shim/sync"
chmod 755 "$shim/sync"
root="$work/root-rollback"
build_root "$root"
before=$(tree_state "$root")
check_fails 'a failure after every file is in place fails the install' env PATH="$shim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=400 sh "$here/install.sh" "$stage"
check 'failed install rolls back to the exact original tree (including the new directory)' test "$before" = "$(tree_state "$root")"

echo '== rollback.sh =='

root="$work/root-rb-modified"
build_root "$root"
install "$root" > /dev/null 2>&1
printf '# edited\n' >> "$root/etc/init.d/S41doorview-network"
before=$(tree_state "$root")
check_fails 'rollback refuses a modified boot hook' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh" "$stage"
check 'refusal changes nothing (modified hook)' test "$before" = "$(tree_state "$root")"

root="$work/root-rb-module"
build_root "$root"
install "$root" > /dev/null 2>&1
printf 'x' >> "$root/etc/doorview/syslink_poll.ko"
before=$(tree_state "$root")
check_fails 'rollback refuses a modified module' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh" "$stage"
check 'refusal changes nothing (modified module)' test "$before" = "$(tree_state "$root")"

root="$work/root-rb-config"
build_root "$root"
install "$root" > /dev/null 2>&1
printf 'secret\n' > "$root/etc/doorview/station.hex"
check 'rollback succeeds with a configuration present' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh" "$stage"
check 'rollback keeps the Wi-Fi configuration by default' test -f "$root/etc/doorview/station.hex"
check 'rollback removed the hooks' test ! -e "$root/etc/init.d/S39doorview" -a ! -e "$root/etc/init.d/S41doorview-network"
check 'rollback with --purge-config removes the configuration' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh" "$stage" --purge-config
check 'purge leaves no configuration' test ! -e "$root/etc/doorview/station.hex"
check 'purge leaves the now-empty directory' test -d "$root/etc/doorview" -a -z "$(ls -A "$root/etc/doorview")"

echo '== configure.sh =='

conf="$work/conf"
mkdir -p "$conf"
valid_station() { printf 'ab%.0s' $(seq 1 31); printf 00; printf 'cd%.0s' $(seq 1 31); printf '00\n'; }
valid_station > "$conf/station.hex"
printf '192.0.2.10/24\n' > "$conf/address"
printf '02:00:00:00:00:01\n' > "$conf/mac"

configure() {
    DOORVIEW_ROOT=$1 sh "$here/configure.sh" "${2:-$conf}" ${3:+"$3"}
}

root="$work/root-conf"
build_root "$root"
install "$root" > /dev/null 2>&1
check 'configure installs the three files' configure "$root"
check 'station.hex is private' test "$(mode_of "$root/etc/doorview/station.hex")" = 600
check 'address is private' test "$(mode_of "$root/etc/doorview/address")" = 600
check 'mac is private' test "$(mode_of "$root/etc/doorview/mac")" = 600
check 'installed station.hex matches' cmp -s "$conf/station.hex" "$root/etc/doorview/station.hex"
check_fails 'configure does not overwrite without --replace' configure "$root"
check 'configure overwrites with --replace' configure "$root" "$conf" --replace
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
check 'configure prints no credentials' test -z "$(DOORVIEW_ROOT=$root sh "$here/configure.sh" "$conf" --replace 2>&1 | grep -E 'abab|192\.0\.2|02:00')"

try_bad() {
    case_dir="$work/conf-bad-$1"
    rm -rf "$case_dir"
    cp -R "$conf" "$case_dir"
    printf '%s\n' "$2" > "$case_dir/$3"
    broken_root="$work/root-conf-bad-$1"
    rm -rf "$broken_root"
    build_root "$broken_root"
    install "$broken_root" > /dev/null 2>&1
    before=$(tree_state "$broken_root")
    if DOORVIEW_ROOT=$broken_root sh "$here/configure.sh" "$case_dir" > /dev/null 2>&1; then
        return 1
    fi
    [ "$before" = "$(tree_state "$broken_root")" ]
}

check 'a station.hex that is too short is rejected, nothing written' try_bad short 'abcd' station.hex
check 'a station.hex with non-hex characters is rejected' try_bad nothex "$(printf 'zz%.0s' $(seq 1 64))" station.hex
check 'a station.hex whose SSID fills all 32 bytes is rejected' try_bad ssidfull "$(printf 'ab%.0s' $(seq 1 32); printf 'cd%.0s' $(seq 1 31); printf 00)" station.hex
check 'a station.hex whose passphrase fills all 32 bytes is rejected' try_bad passfull "$(printf 'ab%.0s' $(seq 1 31); printf 00; printf 'cd%.0s' $(seq 1 32))" station.hex
check 'a station.hex with an empty SSID is rejected' try_bad ssidempty "$(printf '00%.0s' $(seq 1 32); printf 'cd%.0s' $(seq 1 31); printf 00)" station.hex
check 'a station.hex with an empty passphrase is rejected' try_bad passempty "$(printf 'ab%.0s' $(seq 1 31); printf 00; printf '00%.0s' $(seq 1 32))" station.hex
check 'an address without a prefix length is rejected' try_bad noprefix '192.0.2.10' address
check 'an address with a hostname is rejected' try_bad hostname 'camera.local/24' address
check 'a prefix length above 32 is rejected' try_bad prefix33 '192.0.2.10/33' address
check 'a mac with the wrong separator is rejected' try_bad macsep '02-00-00-00-00-01' mac
check 'a short mac is rejected' try_bad macshort '02:00:00:00:00' mac

root="$work/root-conf-missing"
build_root "$root"
install "$root" > /dev/null 2>&1
rm "$conf/mac"
check_fails 'a missing file in the configuration directory is rejected' configure "$root"
printf '02:00:00:00:00:01\n' > "$conf/mac"

root="$work/root-conf-nodir"
build_root "$root"
check_fails 'configure refuses when the base is not installed' configure "$root"

root="$work/root-conf-symlink"
build_root "$root"
install "$root" > /dev/null 2>&1
ln -s "$conf/mac" "$work/conf-link-mac"
link_conf="$work/conf-link"
mkdir -p "$link_conf"
cp "$conf/station.hex" "$conf/address" "$link_conf/"
ln -s "$conf/mac" "$link_conf/mac"
check_fails 'a symlink in the configuration directory is rejected' configure "$root" "$link_conf"

echo
echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
