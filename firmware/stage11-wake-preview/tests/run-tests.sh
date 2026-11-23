#!/bin/sh
# Local tests for the LCD boot hook that starts the preview after a front-button wake-up, and for its installer.
# They never touch the camera; everything runs under a temporary directory.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
hook=$here/payload/etc/init.d/S96doorview-lcd
old_hook=$here/../stage2-lcd/payload/etc/init.d/S96doorview-lcd
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

sleep_s() { python3 -c "import time; time.sleep($1)"; }

# wait_for_line <file> <text> <tenths>
wait_for_line() {
    i=0
    while [ "$i" -lt "$3" ]; do
        grep -qF -- "$2" "$1" 2> /dev/null && return 0
        sleep_s 0.1
        i=$((i + 1))
    done
    return 1
}

echo '== the boot hook =='

# Stand-ins: wget answers only once the file "ready" exists; the service and the preview record their calls.
bin="$work/bin"
mkdir -p "$bin"
cat > "$bin/wget" << SHIM
#!/bin/sh
[ -e "$work/ready" ]
SHIM
chmod 755 "$bin/wget"
printf '#!/bin/sh\necho "service $1" >> "%s/calls"\n' "$work" > "$work/service"
printf '#!/bin/sh\necho preview >> "%s/calls"\necho "preview ran"\n' "$work" > "$work/preview"

run_hook() { # <reason or ""> [extra environment]
    : > "$work/calls"
    rm -f "$work/reason"
    [ -z "$1" ] || printf '%s\n' "$1" > "$work/reason"
    shift
    env PATH="$bin:$PATH" DOORVIEW_LCD_SERVICE="$work/service" DOORVIEW_LCD_PREVIEW="$work/preview" \
        DOORVIEW_LCD_PREVIEW_LOG="$work/preview.log" DOORVIEW_LCD_BOOT_LOG="$work/boot.log" \
        DOORVIEW_REASON_FILE="$work/reason" DOORVIEW_LCD_DELAY=1 DOORVIEW_LCD_WAIT_TENTHS=30 "$@" sh "$hook" start
}

touch "$work/ready"
before=$(python3 -c 'import time; print(time.time())')
check 'the hook returns at once after a front-button wake-up' run_hook wifikey
check 'the preview starts after a front-button wake-up' wait_for_line "$work/calls" preview 20
after=$(python3 -c 'import time; print(time.time())')
check 'and without the 20 s delay of a normal start (here 1 s)' python3 -c "import sys; sys.exit(0 if $after - $before < 0.9 else 1)"
check 'the service is started first' test "$(head -n 1 "$work/calls")" = 'service start'
check 'the preview output goes to the listener log file' grep -qx 'preview ran' "$work/preview.log"

rm -f "$work/ready"
run_hook wifikey
sleep_s 0.8
check 'while Majestic gives no picture the preview waits' test ! -s "$work/calls"
touch "$work/ready"
check 'and starts as soon as Majestic answers' wait_for_line "$work/calls" preview 30

run_hook key
check 'the preview starts after reason key too' wait_for_line "$work/calls" preview 20

run_hook pir
sleep_s 0.5
check_fails 'after a PIR wake-up nothing starts at once' grep -q . "$work/calls"
check 'the service starts after the delay, as before' wait_for_line "$work/calls" 'service start' 30
sleep_s 0.5
check_fails 'and the preview does not start by itself' grep -q preview "$work/calls"

run_hook ''
check 'without a wake-up reason the service starts after the delay' wait_for_line "$work/calls" 'service start' 30
sleep_s 0.5
check_fails 'and the preview does not start by itself' grep -q preview "$work/calls"

rm -f "$work/ready"
run_hook wifikey DOORVIEW_LCD_WAIT_TENTHS=5
sleep_s 1.5
check_fails 'if Majestic never answers, neither the service nor the preview starts' grep -q . "$work/calls"

: > "$work/calls"
check 'stop is passed to the service' env DOORVIEW_LCD_SERVICE="$work/service" sh "$hook" stop
check 'as before' grep -qx 'service stop' "$work/calls"
check_fails 'an unknown action is refused' env DOORVIEW_LCD_SERVICE="$work/service" sh "$hook" frobnicate
check 'a normal start is the stock behaviour (same delayed line as the stage 2 hook)' grep -qF '( sleep "$delay"; sh "$service" start )' "$hook"

echo '== install.sh =='

build_stage() {
    target=$1
    mkdir -p "$target"
    cp "$hook" "$target/"
    (cd "$target" && shasum -a 256 S96doorview-lcd > SHA256SUMS)
}

build_root() {
    fixture=$1
    mkdir -p "$fixture/etc/doorview" "$fixture/etc/init.d"
    cp "$old_hook" "$fixture/etc/init.d/S96doorview-lcd"
    printf '#!/bin/sh\n# rcS\n' > "$fixture/etc/init.d/rcS"
    printf '#!/bin/sh\n# S97\n' > "$fixture/etc/init.d/S97doorview-mqtt"
    chmod 755 "$fixture/etc/init.d/"*
    printf 'host=192.0.2.20\n' > "$fixture/etc/doorview/mqtt.conf"
    printf 'stage 9 rcS\n' > "$fixture/etc/doorview/rcS.before-early"
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

root="$work/root-success"
build_root "$root"
before=$(tree_state "$root")
check 'installs on the tested layout' install_stage "$root"
check 'the hook is replaced by the new one' cmp -s "$hook" "$root/etc/init.d/S96doorview-lcd"
check 'the hook stays executable for everyone' test "$(mode_of "$root/etc/init.d/S96doorview-lcd")" = 755
check 'the previous hook is kept in /etc/doorview' cmp -s "$old_hook" "$root/etc/doorview/S96doorview-lcd.before-wake"
check 'the backup is private' test "$(mode_of "$root/etc/doorview/S96doorview-lcd.before-wake")" = 600
check 'no copy of the hook is left in /etc/init.d, where the stock rcS would run it' test "$(ls "$root/etc/init.d" | grep -c 'before-wake')" = 0
check 'the other files are untouched' sh -c "test \"\$(cat '$root/etc/init.d/rcS')\" = \"\$(printf '#!/bin/sh\n# rcS')\" && test \"\$(cat '$root/etc/doorview/rcS.before-early')\" = 'stage 9 rcS'"
check 'no temporary files left behind' test -z "$(find "$root/etc" -name '.*' -not -name . -not -name .. 2> /dev/null)"
check_fails 'a second install is refused' install_stage "$root"
check 'rollback succeeds' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"
check 'rollback restores the exact original tree' test "$before" = "$(tree_state "$root")"
check 'rollback gives the hook its mode back' test "$(mode_of "$root/etc/init.d/S96doorview-lcd")" = 755
check_fails 'a second rollback is refused' env DOORVIEW_ROOT="$root" sh "$here/rollback.sh"

root="$work/root-wrong"
build_root "$root"
printf 'x' >> "$root/etc/init.d/S96doorview-lcd"
before=$(tree_state "$root")
check_fails 'refuses an unexpected installed hook' install_stage "$root"
check 'refusal changes nothing (unexpected hook)' test "$before" = "$(tree_state "$root")"

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
printf 'x' > "$root/etc/doorview/S96doorview-lcd.before-wake"
before=$(tree_state "$root")
check_fails 'refuses when a backup already exists' install_stage "$root"
check 'refusal changes nothing (existing backup)' test "$before" = "$(tree_state "$root")"

bad_stage="$work/stage-bad"
build_stage "$bad_stage"
printf 'x' >> "$bad_stage/S96doorview-lcd"
root="$work/root-bad-stage"
build_root "$root"
before=$(tree_state "$root")
check_fails 'refuses a stage file that does not match SHA256SUMS' env DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$bad_stage"
check 'refusal changes nothing (bad stage)' test "$before" = "$(tree_state "$root")"

empty_stage="$work/stage-empty-manifest"
build_stage "$empty_stage"
printf 'x' >> "$empty_stage/S96doorview-lcd"
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
check_fails 'a failure after the hook is in place fails the install' env PATH="$shim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
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
[ "\$count" -gt 1 ] && exit 1
exec "$real_mktemp" "\$@"
SHIM
chmod 755 "$mkshim/mktemp"
rm -f "$work/mktemp-count"
root="$work/root-restore-fails"
build_root "$root"
check_fails 'an install whose restore also fails reports failure' env PATH="$mkshim:$PATH" DOORVIEW_ROOT="$root" DOORVIEW_MOUNTS="$mounts_ok" DOORVIEW_FREE_KB=288 sh "$here/install.sh" "$stage"
check 'the backup of the hook is kept when the restore failed' cmp -s "$old_hook" "$root/etc/doorview/S96doorview-lcd.before-wake"

echo '== rollback.sh =='

root="$work/root-rb-damaged"
build_root "$root"
install_stage "$root" > /dev/null 2>&1
printf 'x' >> "$root/etc/doorview/S96doorview-lcd.before-wake"
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
