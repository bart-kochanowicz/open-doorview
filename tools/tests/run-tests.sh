#!/bin/sh
# Tests for the host-side helper tools that need no camera.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

check() {
    description=$1
    shift
    if "$@" > /dev/null 2>&1; then passed=$((passed + 1)); echo "ok   - $description"; else failed=$((failed + 1)); echo "FAIL - $description"; fi
}
check_fails() {
    description=$1
    shift
    if "$@" > /dev/null 2>&1; then failed=$((failed + 1)); echo "FAIL - $description (command succeeded)"; else passed=$((passed + 1)); echo "ok   - $description"; fi
}
mode_of() { stat -f %Lp "$1" 2> /dev/null || stat -c %a "$1"; }

printf 'correct horse 12345\n' > "$work/pass"
make_config() {
    python3 -I "$here/make-wifi-config.py" --passphrase-file "$work/pass" "$@"
}

echo '== make-wifi-config.py =='
check 'writes the three files' make_config --ssid TestNet --address 192.0.2.10/24 --mac 70aabbccddee --out "$work/ok"
check 'station.hex is private' test "$(mode_of "$work/ok/station.hex")" = 600
check 'address is private' test "$(mode_of "$work/ok/address")" = 600
check 'the mac is normalised to colons' test "$(cat "$work/ok/mac")" = 70:aa:bb:cc:dd:ee
check 'the address keeps its prefix' test "$(cat "$work/ok/address")" = 192.0.2.10/24
check 'station.hex is 128 hex characters and a newline' test "$(wc -c < "$work/ok/station.hex" | tr -d ' ')" = 129
check 'station.hex holds the SSID and passphrase in 32-byte NUL-padded fields' python3 -I -c "
raw = bytes.fromhex(open('$work/ok/station.hex').read().strip())
assert raw[:32] == b'TestNet'.ljust(32, b'\0'), raw[:32]
assert raw[32:] == b'correct horse 12345'.ljust(32, b'\0'), raw[32:]
"
check_fails 'an existing non-empty output directory is refused' make_config --ssid TestNet --address 192.0.2.10/24 --mac 70aabbccddee --out "$work/ok"
check_fails 'an address without a prefix is refused' make_config --ssid TestNet --address 192.0.2.10 --mac 70aabbccddee --out "$work/a1"
check_fails 'an IPv6 address is refused' make_config --ssid TestNet --address 2001:db8::1/64 --mac 70aabbccddee --out "$work/a2"
check_fails 'the network address is refused' make_config --ssid TestNet --address 192.0.2.0/24 --mac 70aabbccddee --out "$work/a3"
check_fails 'a multicast mac is refused' make_config --ssid TestNet --address 192.0.2.10/24 --mac 71aabbccddee --out "$work/a4"
check_fails 'a short mac is refused' make_config --ssid TestNet --address 192.0.2.10/24 --mac 70aabbccdd --out "$work/a5"
check_fails 'an SSID of 32 bytes is refused (the drivers need a NUL after the field)' make_config --ssid "$(printf 'n%.0s' $(seq 1 32))" --address 192.0.2.10/24 --mac 70aabbccddee --out "$work/a6"
check 'an SSID of 31 bytes is accepted' make_config --ssid "$(printf 'n%.0s' $(seq 1 31))" --address 192.0.2.10/24 --mac 70aabbccddee --out "$work/b1"
check 'a 31-byte SSID leaves the last byte of its field NUL' python3 -I -c "
raw = bytes.fromhex(open('$work/b1/station.hex').read().strip())
assert raw[31] == 0 and raw[63] == 0
"
printf 'short\n' > "$work/pass-short"
check_fails 'a passphrase shorter than 8 characters is refused' python3 -I "$here/make-wifi-config.py" --passphrase-file "$work/pass-short" --ssid TestNet --address 192.0.2.10/24 --mac 70aabbccddee --out "$work/a7"
printf '%032d\n' 0 > "$work/pass-long"
printf '%031d\n' 0 > "$work/pass-max"
check 'a passphrase of 31 bytes is accepted' python3 -I "$here/make-wifi-config.py" --passphrase-file "$work/pass-max" --ssid TestNet --address 192.0.2.10/24 --mac 70aabbccddee --out "$work/b2"
check_fails 'a passphrase of 32 bytes is refused' python3 -I "$here/make-wifi-config.py" --passphrase-file "$work/pass-long" --ssid TestNet --address 192.0.2.10/24 --mac 70aabbccddee --out "$work/a8"
check 'nothing was left behind by the refused runs' test ! -e "$work/a1" -a ! -e "$work/a4" -a ! -e "$work/a8"

echo '== jffs2-files.py =='
check_fails 'an unknown command prints the usage' python3 -I "$here/jffs2-files.py" bogus "$work/pass"
printf 'not a jffs2 image' > "$work/junk"
python3 -I "$here/tests/make-jffs2-fixture.py" "$work/fixture.jffs2"
check 'the newest data of a file wins' test "$(python3 -I "$here/jffs2-files.py" cat "$work/fixture.jffs2" mac)" = 70aabbccddee
check 'a file made of two data nodes is assembled in order' test "$(python3 -I "$here/jffs2-files.py" cat "$work/fixture.jffs2" big | wc -c | tr -d ' ')" = 150
check 'the second data node lands at its offset' test "$(python3 -I "$here/jffs2-files.py" cat "$work/fixture.jffs2" big | tail -c 50)" = "$(printf 'B%.0s' $(seq 1 50))"
check 'an uncompressed node is read' test "$(python3 -I "$here/jffs2-files.py" cat "$work/fixture.jffs2" raw)" = 'plain text'
check 'an rtime-compressed node is expanded' test "$(python3 -I "$here/jffs2-files.py" cat "$work/fixture.jffs2" rt)" = ababa
check 'a renamed file is listed under its newest name only' test "$(python3 -I "$here/jffs2-files.py" list "$work/fixture.jffs2" | cut -f1 | sort | tr '\n' ' ')" = 'big mac newname raw rt '
check 'an image without JFFS2 nodes lists nothing' test -z "$(python3 -I "$here/jffs2-files.py" list "$work/junk")"
check_fails 'cat of a missing file fails' python3 -I "$here/jffs2-files.py" cat "$work/junk" mac

echo
echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
