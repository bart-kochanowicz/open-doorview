#!/bin/sh
# Tests the doorview-mqtt logic against a real Mosquitto broker (Docker), using the host build and a fake kernel log.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
broker=doorview-mqtt-test-$$
port=18883
passed=0
failed=0
daemon_pid=
sub_pid=

cleanup() {
    [ -z "$daemon_pid" ] || kill -9 "$daemon_pid" 2> /dev/null
    [ -z "$sub_pid" ] || kill "$sub_pid" 2> /dev/null
    [ -z "${majestic_pid:-}" ] || kill -9 "$majestic_pid" 2> /dev/null
    [ -z "${snap_sub_pid:-}" ] || kill "$snap_sub_pid" 2> /dev/null
    docker rm -f "$broker" > /dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

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

check_not() {
    description=$1
    shift
    if "$@" > /dev/null 2>&1; then
        failed=$((failed + 1))
        echo "FAIL - $description"
    else
        passed=$((passed + 1))
        echo "ok   - $description"
    fi
}

# wait_for <file> <fixed text> <seconds>
wait_for() {
    waited=0
    while [ "$waited" -lt "$(($3 * 10))" ]; do
        grep -qF -- "$2" "$1" 2> /dev/null && return 0
        python3 -c 'import time; time.sleep(0.1)'
        waited=$((waited + 1))
    done
    return 1
}

count_of() {
    grep -cF -- "$2" "$1" 2> /dev/null
}

ha_password=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
camera_password=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
noread_password=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
mkdir -p "$work/broker"
cat > "$work/broker/mosquitto.conf" << EOF
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
acl_file /mosquitto/config/acl
persistence false
# As in production: a larger packet makes the broker drop the connection.
max_packet_size 524288
EOF
cat > "$work/broker/acl" << 'EOF'
user home-assistant
topic readwrite #

user front-door-noread
topic write doorview/front-door-camera/#

user front-door-camera
topic write doorview/front-door-camera/#
topic write homeassistant/sensor/front-door-camera/+/config
topic write homeassistant/binary_sensor/front-door-camera/+/config
topic write homeassistant/event/front-door-camera/+/config
topic write homeassistant/image/front-door-camera/+/config
topic read doorview/front-door-camera/live/set
EOF
: > "$work/broker/passwd"
docker run --rm -v "$work/broker:/mosquitto/config" eclipse-mosquitto:2 sh -c \
    "mosquitto_passwd -b /mosquitto/config/passwd home-assistant '$ha_password' && mosquitto_passwd -b /mosquitto/config/passwd front-door-camera '$camera_password' && mosquitto_passwd -b /mosquitto/config/passwd front-door-noread '$noread_password'" > /dev/null 2>&1
chmod 644 "$work/broker/passwd" "$work/broker/acl" "$work/broker/mosquitto.conf"

start_broker() {
    docker run -d --name "$broker" -p "127.0.0.1:$port:1883" -v "$work/broker:/mosquitto/config:ro" eclipse-mosquitto:2 > /dev/null 2>&1
    waited=0
    while [ "$waited" -lt 100 ]; do
        docker exec "$broker" mosquitto_pub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t probe -m x > /dev/null 2>&1 && return 0
        python3 -c 'import time; time.sleep(0.1)'
        waited=$((waited + 1))
    done
    return 1
}

start_subscriber() {
    : > "$work/sub.log"
    docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t '#' -v -F '%r|%t|%p' >> "$work/sub.log" 2> /dev/null &
    sub_pid=$!
}

write_config() {
    cat > "$work/mqtt.conf" << EOF
host=127.0.0.1
port=$port
user=front-door-camera
password=$camera_password
node=front-door-camera
name=Front door camera
keepalive=4
kmsg=$work/kmsg
uptime_file=$work/uptime
EOF
}

kmsg_line() {
    seq_number=$((seq_number + 1))
    printf '6,%d,%d,-;%s\n' "$seq_number" "$1" "$2" >> "$work/kmsg"
}

kill_daemon() {
    [ -z "$daemon_pid" ] && return 0
    kill -9 "$daemon_pid" 2> /dev/null
    wait "$daemon_pid" 2> /dev/null
    daemon_pid=
}

snapshot() {
    docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t '#' -W 2 -F '%r|%t|%p' > "$work/retained.log" 2> /dev/null
}

start_daemon() {
    "$work/doorview-mqtt" "$work/mqtt.conf" > "$work/daemon.log" 2>&1 &
    daemon_pid=$!
}

echo '== build =='
cc -Wall -Wextra -Werror -O2 -o "$work/doorview-mqtt" "$here/doorview-mqtt.c" "$here/sys-host.c"
check 'host build has no warnings' test -x "$work/doorview-mqtt"

start_broker
check 'broker starts' docker exec "$broker" mosquitto_pub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t probe -m x
start_subscriber

seq_number=100
: > "$work/kmsg"
kmsg_line 1000000 'doorview_control: command=a2 length=12'
kmsg_line 1000100 'doorview_power: command=a2 count=44 length=12 head=8a a2 01 01 00 00 0c 00 payload=02 01 63 00'
kmsg_line 1000200 'doorview_control: command=a5 length=8'
printf '123.45 98.76\n' > "$work/uptime"
write_config

echo '== normal operation =='
start_daemon
check 'daemon connects and marks itself online (retained)' wait_for "$work/sub.log" '|doorview/front-door-camera/availability|online' 8
for entity in 'sensor/front-door-camera/battery' 'binary_sensor/front-door-camera/external_power' 'sensor/front-door-camera/power_status' 'sensor/front-door-camera/uptime' 'event/front-door-camera/button'; do
    check "discovery published (retained) for $entity" wait_for "$work/sub.log" "|homeassistant/$entity/config|" 5
done
check 'battery from the replayed kernel log is published retained' wait_for "$work/sub.log" '|doorview/front-door-camera/battery|99' 5
check 'external power ON from usb=1' wait_for "$work/sub.log" '|doorview/front-door-camera/external_power|ON' 5
check 'raw power status published' wait_for "$work/sub.log" '|doorview/front-door-camera/power_status|2' 5
check 'uptime published as whole seconds' wait_for "$work/sub.log" 'doorview/front-door-camera/uptime|123' 5
check 'a button press that is only in the replayed history is ignored' test "$(count_of "$work/sub.log" 'doorview/front-door-camera/button|')" = 0

python3 - "$work/sub.log" << 'PY'
import json, sys
bad = 0
seen = 0
for line in open(sys.argv[1]):
    retain, topic, payload = line.rstrip('\n').split('|', 2)
    if topic.endswith('/config'):
        seen += 1
        data = json.loads(payload)
        assert data['unique_id'].startswith('front-door-camera_'), data
        assert data['availability_topic'] == 'doorview/front-door-camera/availability'
        assert data['state_topic'].startswith('doorview/front-door-camera/')
        assert data['device']['identifiers'] == ['front-door-camera']
        assert data['device']['model'] == 'RH-PD10'
sys.exit(0 if seen == 5 else 1)
PY
check 'discovery payloads are valid JSON with a shared device block' test $? -eq 0
check_not 'no motion entity or state unless motion=1 is configured' grep -qE 'front-door-camera/motion' "$work/sub.log"

snapshot
check 'a late subscriber gets availability online as retained' grep -qF '1|doorview/front-door-camera/availability|online' "$work/retained.log"
check 'a late subscriber gets the five discovery configs as retained' test "$(grep -c '^1|homeassistant/.*/config|' "$work/retained.log")" = 5
check 'a late subscriber gets battery 99 as retained' grep -qF '1|doorview/front-door-camera/battery|99' "$work/retained.log"
check 'a late subscriber gets external power as retained' grep -qF '1|doorview/front-door-camera/external_power|ON' "$work/retained.log"

echo '== button =='
kmsg_line 5000000 'doorview_control: command=a5 length=8'
kmsg_line 5000010 'doorview_control: command=a5 length=8'
kmsg_line 5000120 'doorview_control: command=a5 length=8'
check 'a burst of records is one press (not retained)' wait_for "$work/sub.log" '0|doorview/front-door-camera/button|{"event_type":"press"}' 5
python3 -c 'import time; time.sleep(1)'
check 'exactly one event for the burst' test "$(count_of "$work/sub.log" 'doorview/front-door-camera/button|')" = 1
kmsg_line 9000000 'doorview_control: command=a5 length=8'
check 'a later press is a second event' wait_for "$work/sub.log" 'doorview/front-door-camera/button|{"event_type":"press"}' 5
python3 -c 'import time; time.sleep(1)'
check 'two presses, two events' test "$(count_of "$work/sub.log" 'doorview/front-door-camera/button|')" = 2
snapshot
check_not 'button events are not retained' grep -q '^[01]|doorview/front-door-camera/button|' "$work/retained.log"

echo '== power changes =='
kmsg_line 10000000 'doorview_power: command=a2 count=44 length=12 head=8a a2 01 01 00 00 0c 00 payload=01 00 63 00'
check 'unplugging USB publishes OFF' wait_for "$work/sub.log" '|doorview/front-door-camera/external_power|OFF' 5
check 'status changes to 1' wait_for "$work/sub.log" '|doorview/front-door-camera/power_status|1' 5
kmsg_line 11000000 'doorview_power: command=a2 count=44 length=12 head=8a a2 01 01 00 00 0c 00 payload=01 00 65 00'
python3 -c 'import time; time.sleep(1.5)'
check 'a capacity above 100 is not published' test "$(count_of "$work/sub.log" 'battery|101')" = 0
kmsg_line 11000100 'doorview_power: command=a2 count=44 length=12 head=8a a2 01 01 00 00 0c 00 payload=01 00 57 00'
check 'a valid new capacity is published' wait_for "$work/sub.log" '|doorview/front-door-camera/battery|87' 5
kmsg_line 12000000 'doorview_power: command=a2 count=44 length=12 head=8a a2 01 01 00 00 0c 00 payload=02 01 57 00'
check 'plugging USB back publishes ON' wait_for "$work/sub.log" '|doorview/front-door-camera/external_power|ON' 5
# The last record has no fresh capacity (-1): the cached 87 must survive.
kmsg_line 13000000 'doorview_power: command=a2 count=44 length=12 head=8a a2 01 01 00 00 0c 00 payload=02 01 ff ff'
python3 -c 'import time; time.sleep(1.5)'
check 'a negative capacity (no fresh reading) is not published' test "$(count_of "$work/sub.log" 'battery|-1')" = 0

echo '== availability on a crash =='
kill_daemon
check 'broker publishes the last will (offline) after the keepalive' wait_for "$work/sub.log" '|doorview/front-door-camera/availability|offline' 12
snapshot
check 'the last will is retained' grep -qF '1|doorview/front-door-camera/availability|offline' "$work/retained.log"

echo '== restart =='
: > "$work/sub.log"
start_daemon
check 'restart marks the device online again' wait_for "$work/sub.log" '|doorview/front-door-camera/availability|online' 8
check 'restart republishes the latest state from the kernel log' wait_for "$work/sub.log" '|doorview/front-door-camera/battery|87' 5
check 'restart does not replay old button presses' test "$(count_of "$work/sub.log" 'doorview/front-door-camera/button|')" = 0

echo '== broker outage =='
docker stop "$broker" > /dev/null 2>&1
python3 -c 'import time; time.sleep(3)'
check 'daemon keeps running while the broker is down' kill -0 "$daemon_pid"
kill "$sub_pid" 2> /dev/null
docker start "$broker" > /dev/null 2>&1
start_subscriber
check 'daemon reconnects by itself after the broker returns' wait_for "$work/sub.log" 'doorview/front-door-camera/availability|online' 40

echo '== authentication and ACL =='
kill_daemon
wait_for "$work/sub.log" '|doorview/front-door-camera/availability|offline' 12
: > "$work/sub.log"
sed -i.bak "s/^password=.*/password=wrong/" "$work/mqtt.conf"
start_daemon
python3 -c 'import time; time.sleep(4)'
check 'a wrong password publishes nothing' test ! -s "$work/sub.log"
check 'the refusal is logged' grep -q 'broker refused the connection' "$work/daemon.log"
check 'the daemon stays alive and keeps retrying with backoff' kill -0 "$daemon_pid"
check 'the password never appears in the log' test "$(count_of "$work/daemon.log" "$camera_password")" = 0
kill_daemon
: > "$work/sub.log"
docker exec "$broker" mosquitto_pub -h 127.0.0.1 -u front-door-camera -P "$camera_password" -t 'other/topic' -m x > /dev/null 2>&1
docker exec "$broker" mosquitto_pub -h 127.0.0.1 -u front-door-camera -P "$camera_password" -t 'doorview/front-door-camera/probe' -m allowed > /dev/null 2>&1
python3 -c 'import time; time.sleep(1)'
check 'the camera user can publish under its own prefix' grep -qF 'doorview/front-door-camera/probe|allowed' "$work/sub.log"
check_not 'the camera user cannot publish elsewhere (ACL)' grep -qF 'other/topic' "$work/sub.log"

echo '== a broker that drops the connection right after CONNACK =='
# The broker accepts, answers CONNECT with CONNACK, and closes. The daemon's first publishes then hit a closed
# socket. It must neither be killed by SIGPIPE nor parse its reset receive buffer (an ASan/UBSan build catches that).
cc -fsanitize=address,undefined -fno-sanitize-recover=undefined -g -O1 -o "$work/doorview-mqtt-asan" "$here/doorview-mqtt.c" "$here/sys-host.c"
cat > "$work/dropping-broker.py" << 'PYEOF'
import socket, sys
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', int(sys.argv[1])))
server.listen(5)
while True:
    connection, _ = server.accept()
    connection.recv(4096)
    connection.sendall(b'\x20\x02\x00\x00')
    connection.close()
    open(sys.argv[2], 'a').write('x\n')
PYEOF
: > "$work/drops.log"
python3 "$work/dropping-broker.py" 18884 "$work/drops.log" &
dropping_pid=$!
python3 -c 'import time; time.sleep(1)'
sed "s/^port=.*/port=18884/" "$work/mqtt.conf" > "$work/mqtt-drop.conf"
"$work/doorview-mqtt-asan" "$work/mqtt-drop.conf" > "$work/daemon-drop.log" 2>&1 &
drop_daemon_pid=$!
python3 -c 'import time; time.sleep(9)'
check 'the daemon survives a broker that closes after CONNACK' kill -0 "$drop_daemon_pid"
check 'it keeps reconnecting' test "$(wc -l < "$work/drops.log" | tr -d ' ')" -ge 2
check_not 'the sanitizers report nothing' grep -qE 'AddressSanitizer|runtime error' "$work/daemon-drop.log"
kill -9 "$drop_daemon_pid" "$dropping_pid" 2> /dev/null
wait "$drop_daemon_pid" "$dropping_pid" 2> /dev/null

echo '== motion =='
# A stand-in for Majestic's /metrics/motion. Files in $work/mj steer it: total (the counter), mode (normal, auth,
# partial = last line without a newline, nocounter, hold = keeps the connection open after answering).
mkdir -p "$work/mj"
cat > "$work/fake-majestic.py" << 'PYEOF'
import os, socket, sys, threading, time
port, state = int(sys.argv[1]), sys.argv[2]
def read(name, default):
    try:
        return open(os.path.join(state, name)).read().strip() or default
    except OSError:
        return default
HELP = ('# HELP md_onsets_blanked_total Changes the camera made to its own picture -- a lamp, the IR-cut filter, colour '
        'and grey, a pan/tilt turn, a zoom or a focus pass -- that held back a motion start the detector reported\n'
        '# TYPE md_onsets_blanked_total counter\nmd_onsets_blanked_total 0\n'
        '# HELP md_rects_recv_total Number of rectangles returned by HW MD algorithm.\n'
        '# TYPE md_rects_recv_total counter\nmd_rects_recv_total %s\n'
        '# HELP md_rects_acc_total Number of rectangles fit into ROI.\n# TYPE md_rects_acc_total counter\n')
def serve_image(conn, request_line):
    mode = read('imgmode', 'normal')
    image = open(os.path.join(state, 'img'), 'rb').read()
    if mode == 'notfound':
        # A valid JPEG body behind a 404: only the status line says it is not the picture.
        conn.sendall(b'HTTP/1.0 404 Not Found\r\nContent-Length: %d\r\n\r\n' % len(image) + image)
        return
    if mode == 'html':
        image = b'<html>login</html>'
    elif mode == 'truncated':
        image = image[:-2]
    conn.sendall(b'HTTP/1.0 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n' % len(image) + image)
def serve(conn):
    try:
        request = conn.recv(4096)
        line = request.split(b'\r\n', 1)[0]
        open(os.path.join(state, 'reqs'), 'ab').write(line + b'\n')
        if line.startswith(b'GET /image.jpg'):
            serve_image(conn, line)
            return
        if line.startswith(b'GET /metrics/night'):
            # The file night holds "enabled gain pending"; no file is a Majestic without these metrics.
            values = read('night', '').split()
            if len(values) != 3:
                conn.sendall(b'HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n')
                return
            body = ('# HELP night_enabled Is night mode enabled\n# TYPE night_enabled gauge\nnight_enabled %s\n'
                    '# TYPE night_auto_gain_milli gauge\nnight_auto_gain_milli %s\n'
                    '# TYPE night_auto_pending gauge\nnight_auto_pending %s\n') % tuple(values)
            conn.sendall(b'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n' + body.encode())
            return
        mode, total = read('mode', 'normal'), read('total', '0')
        open(os.path.join(state, 'hits'), 'a').write('x\n')
        if mode == 'auth':
            conn.sendall(b'HTTP/1.0 401 Unauthorized\r\nWWW-Authenticate: Basic realm="x"\r\nContent-Length: 0\r\n\r\n')
            return
        body = HELP % total
        if mode == 'partial':
            body += 'md_rects_acc_total %s' % total
        elif mode != 'nocounter':
            body += 'md_rects_acc_total %s\n' % total
        conn.sendall(b'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n' + body.encode())
        if mode == 'hold':
            time.sleep(3)
    finally:
        conn.close()
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', port))
server.listen(5)
while True:
    connection, _ = server.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
PYEOF
motion_port=18890
set_total() { printf '%s' "$1" > "$work/mj/total"; }
set_mode() { printf '%s' "$1" > "$work/mj/mode"; }
start_majestic() { python3 "$work/fake-majestic.py" "$motion_port" "$work/mj" & majestic_pid=$!; python3 -c 'import time; time.sleep(0.5)'; }
stop_majestic() { [ -z "${majestic_pid:-}" ] || { kill -9 "$majestic_pid" 2> /dev/null; wait "$majestic_pid" 2> /dev/null; majestic_pid=; }; }
motion_count() { count_of "$work/sub.log" "doorview/front-door-camera/motion|$1"; }
sleep_s() { python3 -c "import time; time.sleep($1)"; }

set_total 0
set_mode normal
: > "$work/mj/hits"
start_majestic
write_config
{ cat "$work/mqtt.conf"; printf 'motion=1\nmotion_port=%s\nmotion_hold=2\n' "$motion_port"; } > "$work/mqtt-motion.conf"
: > "$work/sub.log"
"$work/doorview-mqtt-asan" "$work/mqtt-motion.conf" > "$work/daemon-motion.log" 2>&1 &
daemon_pid=$!
check 'with motion=1 the motion entity is discovered' wait_for "$work/sub.log" '|homeassistant/binary_sensor/front-door-camera/motion/config|' 8
check 'the motion entity is a motion sensor with ON/OFF payloads' sh -c "grep -F '|homeassistant/binary_sensor/front-door-camera/motion/config|' '$work/sub.log' | grep -q 'device_class\":\"motion\",\"payload_on\":\"ON\",\"payload_off\":\"OFF'"
check 'the first reading gives a retained OFF (a baseline, not motion)' wait_for "$work/sub.log" '|doorview/front-door-camera/motion|OFF' 5
check 'the counter is polled' test "$(wc -l < "$work/mj/hits" | tr -d ' ')" -ge 1
set_total 5
check 'a rising counter publishes ON' wait_for "$work/sub.log" '|doorview/front-door-camera/motion|ON' 5
check 'it goes OFF again after the hold time without a rise' test "$(for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do [ "$(motion_count OFF)" -ge 2 ] && echo ok && break; sleep_s 0.1; done)" = ok
on_before=$(motion_count ON)
off_before=$(motion_count OFF)
for n in 6 7 8 9 10 11; do set_total "$n"; sleep_s 0.5; done
check 'ON stays on while the counter keeps rising (no OFF in between)' test "$(motion_count OFF)" = "$off_before"
check 'a second burst is a second ON' test "$(motion_count ON)" = "$((on_before + 1))"
check 'it goes OFF after that burst too' wait_for "$work/sub.log" 'doorview/front-door-camera/motion|OFF' 6
sleep_s 3
on_before=$(motion_count ON)
set_total 0
sleep_s 2.5
check 'a counter that goes down (Majestic restarted) is a new baseline, not motion' test "$(motion_count ON)" = "$on_before"
check 'the daemon is alive' kill -0 "$daemon_pid"

set_mode auth
set_total 50
sleep_s 2.5
check 'a 401 page from Majestic is not motion' test "$(motion_count ON)" = "$on_before"
set_mode normal
check 'the counter is picked up again when Majestic answers again' wait_for "$work/sub.log" '|doorview/front-door-camera/motion|ON' 5
sleep_s 4
on_before=$(motion_count ON)
set_mode partial
set_total 99999
sleep_s 2.5
check 'a last line without its newline is not trusted' test "$(motion_count ON)" = "$on_before"
set_mode nocounter
sleep_s 2.5
check 'an answer without the counter (motion detection off) changes nothing' test "$(motion_count ON)" = "$on_before"
check 'the daemon is still alive' kill -0 "$daemon_pid"

set_mode hold
set_total 60
check 'a server that keeps the connection open is read without waiting for it to close' test "$(for i in $(seq 1 30); do [ "$(motion_count ON)" -gt "$on_before" ] && echo ok && break; sleep_s 0.1; done)" = ok
set_mode normal
set_total 70
sleep_s 1.5
stop_majestic
off_before=$(motion_count OFF)
check 'when Majestic disappears while ON the sensor still goes OFF after the hold time' test "$(for i in $(seq 1 80); do [ "$(motion_count OFF)" -gt "$off_before" ] && echo ok && break; sleep_s 0.1; done)" = ok
check 'the daemon survives Majestic being down' kill -0 "$daemon_pid"
snapshot
check 'a late subscriber gets the motion state as retained' grep -qE '^1\|doorview/front-door-camera/motion\|(ON|OFF)$' "$work/retained.log"
check 'the motion run never reconnected (a busy publisher still pings)' test "$(count_of "$work/daemon-motion.log" 'connected')" = 1
check_not 'the broker was never taken for dead while the daemon was publishing' grep -qF 'stopped answering' "$work/daemon-motion.log"
check_not 'the sanitizers report nothing in the motion run' grep -qE 'AddressSanitizer|runtime error' "$work/daemon-motion.log"
check_not 'without snapshot=1 the daemon never asks Majestic for a picture' grep -q 'image.jpg' "$work/mj/reqs"
check_not 'without snapshot=1 no image entity is discovered' grep -q 'homeassistant/image' "$work/sub.log"
kill_daemon
wait_for "$work/sub.log" '|doorview/front-door-camera/availability|offline' 12

echo '== snapshot =='
# The picture is read from Majestic on the camera and published to the broker, so Home Assistant never reaches the
# camera. Binary payloads are compared as hex (mosquitto_sub -F %x).
make_jpeg() { # <size in bytes>
    python3 - "$1" "$work/mj/img" "$work/mj/img.hex" << 'PY'
import os, sys
size = int(sys.argv[1])
data = b'\xff\xd8' + os.urandom(size - 4) + b'\xff\xd9'
open(sys.argv[2], 'wb').write(data)
open(sys.argv[3], 'w').write(data.hex())
PY
}
snap_count() { wc -l < "$work/snap.log" | tr -d ' '; }
last_snap_hex() { tail -n 1 "$work/snap.log" | cut -d'|' -f3; }
wait_snap() { # <count> <seconds>
    for i in $(seq 1 "$(($2 * 10))"); do [ "$(snap_count)" -ge "$1" ] && return 0; sleep_s 0.1; done
    return 1
}
rise() { snap_total=$((snap_total + 5)); set_total "$snap_total"; }
start_snap_daemon() { # <cooldown> [extra config lines, separated by \n]; waits for the baseline reading, so the next rise is a real rise
    { cat "$work/mqtt.conf"; printf 'motion=1\nmotion_port=%s\nmotion_hold=2\nsnapshot=1\nsnapshot_cooldown=%s\n%b\n' "$motion_port" "$1" "${2:-}"; } > "$work/mqtt-snap.conf"
    hits_before=$(wc -l < "$work/mj/hits" | tr -d ' ')
    "$work/doorview-mqtt-asan" "$work/mqtt-snap.conf" > "$work/daemon-snap.log" 2>&1 &
    daemon_pid=$!
    for i in $(seq 1 50); do [ "$(wc -l < "$work/mj/hits" | tr -d ' ')" -gt "$hits_before" ] && break; sleep_s 0.1; done
    sleep_s 0.5
}
kill "$sub_pid" 2> /dev/null
: > "$work/sub.log"
docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t 'doorview/front-door-camera/motion' -t 'doorview/front-door-camera/availability' -t 'homeassistant/#' -F '%r|%t|%p' >> "$work/sub.log" 2> /dev/null &
sub_pid=$!
: > "$work/snap.log"
docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t 'doorview/front-door-camera/snapshot' -F '%r|%l|%x' >> "$work/snap.log" 2> /dev/null &
snap_sub_pid=$!

make_jpeg 12000
set_mode normal
snap_total=0
set_total 0
rm -f "$work/mj/imgmode" "$work/mj/reqs"
start_majestic
write_config
echo '-- one daemon with a long cooldown: edges, bytes, retention'
start_snap_daemon 10
check 'with snapshot=1 an image entity is discovered' wait_for "$work/sub.log" '|homeassistant/image/front-door-camera/snapshot/config|' 8
check 'it points at the snapshot topic and declares JPEG' sh -c "grep -F '|homeassistant/image/front-door-camera/snapshot/config|' '$work/sub.log' | grep -q 'image_topic\":\"doorview/front-door-camera/snapshot\".*content_type\":\"image/jpeg'"
check_not 'the image entity has no state_topic key' sh -c "grep -F '|homeassistant/image/front-door-camera/snapshot/config|' '$work/sub.log' | grep -q state_topic"
check 'no picture without motion' test "$(snap_count)" = 0
rise
check 'a motion edge publishes one picture' wait_snap 1 6
check 'the published bytes are exactly the JPEG Majestic served (12000 bytes)' test "$(last_snap_hex)" = "$(cat "$work/mj/img.hex")"
check 'the payload length is reported as 12000' test "$(tail -n 1 "$work/snap.log" | cut -d'|' -f2)" = 12000
check 'the log records the published picture, its size and the time it took' grep -qE 'snapshot published, 12000 bytes in [0-9]+ ms' "$work/daemon-snap.log"
check 'the request carries the configured path and nothing else' grep -qx 'GET /image.jpg?qfactor=60 HTTP/1.0' "$work/mj/reqs"
docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t 'doorview/front-door-camera/snapshot' -C 1 -W 3 -F '%r|%l' > "$work/snap-retained.log" 2> /dev/null
check 'the picture is retained' grep -qx '1|12000' "$work/snap-retained.log"
# A second, separate edge inside the 10 s cooldown: the hold time (2 s) runs out, the sensor goes OFF, motion starts again.
sleep_s 4.5
rise
sleep_s 2.5
check 'a second edge inside the cooldown publishes no picture' test "$(snap_count)" = 1
# The counter keeps rising for longer than the cooldown: that is one long motion, not a new edge.
for n in $(seq 1 24); do rise; sleep_s 0.5; done
sleep_s 1
check 'a rise that outlasts the cooldown is not a new edge and adds no picture' test "$(snap_count)" = 1
sleep_s 4.5
rise
check 'after the cooldown a new edge publishes a second picture' wait_snap 2 6
kill_daemon

echo '-- a second daemon with a short cooldown: sizes and broken answers'
start_snap_daemon 1
make_jpeg 20000
rise
check 'a 20000-byte picture needs a three-byte length and arrives intact' wait_snap 3 6
check 'the 20000-byte payload is bit for bit the served image' test "$(last_snap_hex)" = "$(cat "$work/mj/img.hex")"
check 'the daemon never reconnected while sending it' test "$(count_of "$work/daemon-snap.log" 'connected')" = 1

# A 1920x1080 picture is 120 to 250 KB. The daemon's limit (320 KiB) stays below the broker's packet limit (512 KiB).
for size in 150000 320000; do
    make_jpeg "$size"
    sleep_s 4
    before=$(snap_count)
    rise
    check "a $size-byte picture is published" wait_snap "$((before + 1))" 8
    check "the $size-byte payload is bit for bit the served image" test "$(last_snap_hex)" = "$(cat "$work/mj/img.hex")"
    check "the $size-byte picture is reported with its length" test "$(tail -n 1 "$work/snap.log" | cut -d'|' -f2)" = "$size"
    check "the daemon did not reconnect after the $size-byte picture" test "$(count_of "$work/daemon-snap.log" 'connected')" = 1
done
for size in 330000 400000; do
    make_jpeg "$size"
    sleep_s 4
    before=$(snap_count)
    rise
    sleep_s 3.5
    check "a $size-byte picture (over the limit) is not published" test "$(snap_count)" = "$before"
done
check 'the log names the oversized pictures' test "$(count_of "$work/daemon-snap.log" 'snapshot: ')" -ge 2
check 'the daemon is still connected after the oversized pictures' test "$(count_of "$work/daemon-snap.log" 'connected')" = 1
make_jpeg 12000

for broken in notfound html truncated; do
    printf '%s' "$broken" > "$work/mj/imgmode"
    sleep_s 4
    before=$(snap_count)
    rise
    sleep_s 3.5
    check "a $broken answer is not published" test "$(snap_count)" = "$before"
done
check 'the log names the non-JPEG answers' test "$(count_of "$work/daemon-snap.log" 'snapshot: not a complete JPEG')" -ge 3
rm -f "$work/mj/imgmode"

stop_majestic
sleep_s 4
before=$(snap_count)
set_total 999
sleep_s 4
check 'with Majestic down nothing is published and nothing crashes' test "$(snap_count)" = "$before"
check 'the daemon is still alive' kill -0 "$daemon_pid"
check_not 'the sanitizers report nothing in the snapshot run' grep -qE 'AddressSanitizer|runtime error' "$work/daemon-snap.log"
kill_daemon

echo '-- motion_min_rate: noise stays below the threshold, movement rises above it'
drive() { # <rectangles per second> <seconds>: raises the fake counter steadily, four times a second
    python3 - "$work/mj/total" "$1" "$2" << 'PY'
import os, sys, time
path, rate, seconds = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
end = time.time() + seconds
while time.time() < end:
    try:
        total = int(open(path).read() or 0)
    except Exception:
        total = 0
    open(path + '.tmp', 'w').write(str(total + int(round(rate * 0.25))))
    os.replace(path + '.tmp', path)
    time.sleep(0.25)
PY
}
now_s() { python3 -c 'import time; print(time.time())'; }
motion_on() { motion_count ON; }
start_majestic
set_mode normal
rm -f "$work/mj/imgmode"
set_total 0
: > "$work/sub.log"
: > "$work/snap.log"
start_snap_daemon 1 'motion_min_rate=20\nmotion_window=3'
sleep_s 4.5
check 'a quiet counter leaves Motion off and publishes no picture' test "$(motion_on)" = 0 -a "$(snap_count)" = 0
drive 8 9
check 'noise of 8 per second, below the threshold of 20, keeps Motion off' test "$(motion_on)" = 0
check 'and publishes no picture' test "$(snap_count)" = 0
# One second at 40 per second after noise of 8 per second gains at most 56 over the 3 s window (about 19 per second),
# below the threshold of 20, whatever the alignment of the polls.
drive 40 1
check 'one second of movement at 40 per second is not 20 per second over the 3 s window' test "$(motion_on)" = 0
drive 40 7
check 'movement at 40 per second, above the threshold, turns Motion on' test "$(motion_on)" -ge 1
check 'and publishes one picture' wait_snap 1 6
sleep_s 4.5
before_on=$(motion_on)
drive 30 1
sleep_s 5
check 'a burst of 30 in one second (about 9 per second over the window) does not turn Motion on' test "$(motion_on)" = "$before_on"
drive 150 1
sleep_s 1
check 'a burst of 150 in one second (about 40 per second over the window) does' test "$(motion_on)" -gt "$before_on"
sleep_s 4.5
# A counter that goes down means Majestic restarted. The history must be forgotten, not compared with the new value.
before_on=$(motion_on)
set_total 200000
sleep_s 1.5
sleep_s 4.5
before_on=$(motion_on)
set_total 10
drive 8 8
check 'a counter that goes down is a new baseline, not movement' test "$(motion_on)" = "$before_on"
check_not 'the sanitizers report nothing with the rate threshold' grep -qE 'AddressSanitizer|runtime error' "$work/daemon-snap.log"
kill_daemon

echo '-- motion_settle: no motion counts for a while after a start or a Majestic restart'
set_total 0
start_snap_daemon 1 'motion_settle=6'
before_on=$(motion_on)
before_snap=$(snap_count)
set_total 5
sleep_s 2.5
check 'a rise of the counter inside the settling time leaves Motion off' test "$(motion_on)" = "$before_on"
check 'and publishes no picture' test "$(snap_count)" = "$before_snap"
sleep_s 4.5
set_total 50
sleep_s 2.5
check 'the same kind of rise after the settling time turns Motion on' test "$(motion_on)" -gt "$before_on"
sleep_s 4.5
before_on=$(motion_on)
set_total 0
sleep_s 1.5
set_total 10
sleep_s 2.5
check 'a counter that goes down (Majestic restarted) starts the settling time again' test "$(motion_on)" = "$before_on"
sleep_s 5
set_total 100
sleep_s 2.5
check 'and the motion after it is reported' test "$(motion_on)" -gt "$before_on"
check_not 'the sanitizers report nothing with motion_settle' grep -qE 'AddressSanitizer|runtime error' "$work/daemon-snap.log"
kill_daemon
set_total 0
start_snap_daemon 1
before_on=$(motion_on)
set_total 5
sleep_s 2.5
check 'without motion_settle the first rise counts at once' test "$(motion_on)" -gt "$before_on"
kill_daemon

echo '-- snapshot_delay_ms: the picture is taken after the delay, not at the edge'
set_total 0
start_snap_daemon 1 'snapshot_delay_ms=2500'
before=$(snap_count)
t0=$(now_s)
set_total 5
wait_snap $((before + 1)) 10
t1=$(now_s)
elapsed=$(python3 -c "print($t1 - $t0)")
check 'with a delay of 2500 ms the picture arrives only after about that time' python3 -c "import sys; sys.exit(0 if $elapsed >= 2.4 else 1)"
check 'and not much later (polling and sending take about a second)' python3 -c "import sys; sys.exit(0 if $elapsed < 5.5 else 1)"
check 'only one picture for one edge' test "$(snap_count)" = "$((before + 1))"
kill_daemon
set_total 0
start_snap_daemon 1
before=$(snap_count)
t0=$(now_s)
set_total 5
wait_snap $((before + 1)) 10
t1=$(now_s)
elapsed=$(python3 -c "print($t1 - $t0)")
check 'without a delay the picture arrives within the polling interval' python3 -c "import sys; sys.exit(0 if $elapsed < 2.2 else 1)"
kill_daemon
stop_majestic
kill "$snap_sub_pid" 2> /dev/null
kill "$sub_pid" 2> /dev/null
start_subscriber


echo '== live view =='
# HA asks for a live view with ON on doorview/<node>/live/set; the camera answers with small pictures on .../live for a
# limited time and reports .../live/state. A real broker and a fake Majestic; the broker's ACL lets the camera read only
# the command topic.
ha_pub() { # <topic> <payload> [extra mosquitto_pub options]
    local topic=$1 payload=$2
    shift 2
    docker exec "$broker" mosquitto_pub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t "$topic" -m "$payload" "$@" > /dev/null 2>&1
}
live_count() { wc -l < "$work/live.log" | tr -d ' '; }
live_state() { grep -a '^1|\|^0|' "$work/live-state.log" 2> /dev/null | tail -n 1 | cut -d'|' -f2; }
wait_live() { # <count> <seconds>
    for i in $(seq 1 "$(($2 * 10))"); do [ "$(live_count)" -ge "$1" ] && return 0; sleep_s 0.1; done
    return 1
}
start_live_subscribers() {
    : > "$work/live.log"
    : > "$work/live-state.log"
    docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t 'doorview/front-door-camera/live' -F '%r|%l|%x' >> "$work/live.log" 2> /dev/null &
    live_sub_pid=$!
    docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t 'doorview/front-door-camera/live/state' -F '%r|%p' >> "$work/live-state.log" 2> /dev/null &
    live_state_pid=$!
    sleep_s 0.5
}
stop_live_subscribers() { kill "$live_sub_pid" "$live_state_pid" 2> /dev/null; }

# The subscriber started at the end of the previous section keeps running: killing a background job right after it was
# started can run the inherited EXIT trap in that half-started subshell and delete the work directory.
make_jpeg 12000
start_majestic
set_mode normal
rm -f "$work/mj/imgmode" "$work/mj/reqs"
snap_total=0
set_total 0
start_live_subscribers
: > "$work/snap.log"
docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t 'doorview/front-door-camera/snapshot' -F '%r|%l|%x' >> "$work/snap.log" 2> /dev/null &
snap_sub_pid=$!

echo '-- a view on demand'
start_snap_daemon 1 'live=1\nlive_seconds=4\nlive_interval_ms=300'
sleep_s 1.5
check 'live=1 publishes the state OFF, retained' test "$(live_state)" = OFF
check 'the state is retained (a late subscriber sees it)' sh -c "docker exec '$broker' mosquitto_sub -h 127.0.0.1 -u home-assistant -P '$ha_password' -t 'doorview/front-door-camera/live/state' -C 1 -W 3 -F '%r|%p' | grep -qx '1|OFF'"
check 'no picture is published before the command' test "$(live_count)" = 0
t0=$(now_s)
ha_pub doorview/front-door-camera/live/set ON
check 'ON starts the pictures' wait_live 3 4
check 'and the state turns ON' wait_for "$work/live-state.log" '|ON' 3
check 'the pictures are exactly the JPEG Majestic served (12000 bytes)' test "$(tail -n 1 "$work/live.log" | cut -d'|' -f3)" = "$(cat "$work/mj/img.hex")"
check 'the request is the configured small picture' grep -qx 'GET /image.jpg?width=640&height=360&qfactor=40 HTTP/1.0' "$work/mj/reqs"
sleep_s 6
t1=$(now_s)
frames=$(live_count)
check 'it ends by itself after live_seconds' test "$(live_state)" = OFF
sleep_s 1.5
check 'and no picture comes after the end' test "$(live_count)" = "$frames"
check 'at most one picture per live_interval_ms (300 ms) over 4 s' test "$frames" -le 15
check 'and a fair number of them' test "$frames" -ge 6
check 'the daemon stayed connected the whole time (keepalive was served)' test "$(count_of "$work/daemon-snap.log" 'connected')" = 1
# A subscriber that is already connected is handed a retained message with the retain flag cleared, so only a late
# subscriber shows whether a picture was left on the broker.
check_not 'no picture is left retained on the broker (a late subscriber gets none)' sh -c "docker exec '$broker' mosquitto_sub -h 127.0.0.1 -u home-assistant -P '$ha_password' -t 'doorview/front-door-camera/live' -C 1 -W 2 -F '%l' | grep -q ."
check 'the log counts the bytes: the pictures are 12000 bytes each' sh -c "grep -E 'live view ended, [0-9]+ pictures, [0-9]+ bytes' '$work/daemon-snap.log' | head -n 1 | awk '{ if (\$5 * 12000 == \$7) exit 0; exit 1 }'"
check 'the log says the view started and ended' sh -c "grep -q 'live view started' '$work/daemon-snap.log' && grep -qE 'live view ended, [0-9]+ pictures, [0-9]+ bytes in [0-9]+ ms' '$work/daemon-snap.log'"

echo '-- OFF and ON again'
: > "$work/live.log"
ha_pub doorview/front-door-camera/live/set ON
wait_live 2 4
ha_pub doorview/front-door-camera/live/set OFF
sleep_s 1
check 'OFF ends the view at once and the state follows' test "$(live_state)" = OFF
frames=$(live_count)
sleep_s 1.5
check 'and no picture comes after OFF' test "$(live_count)" = "$frames"
: > "$work/live.log"
ha_pub doorview/front-door-camera/live/set ON
sleep_s 2.5
ha_pub doorview/front-door-camera/live/set ON
sleep_s 2
before=$(live_count)
sleep_s 1.5
check 'a second ON restarts the time: pictures still come after the first deadline (4 s)' test "$(live_count)" -gt "$before"
sleep_s 4
check 'and it ends after the new deadline' test "$(live_state)" = OFF

echo '-- what the command topic must not do'
: > "$work/live.log"
for payload in on 'ON ' ONN '' OFFER 1 true; do ha_pub doorview/front-door-camera/live/set "$payload"; done
sleep_s 2
check 'other payloads (on, "ON ", ONN, empty, OFFER, 1, true) start nothing' test "$(live_count)" = 0
head -c 70000 /dev/zero | tr '\0' 'x' | docker exec -i "$broker" mosquitto_pub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t doorview/front-door-camera/live/set -s > /dev/null 2>&1
sleep_s 1.5
check 'a 70000-byte payload on the command topic is dropped without disconnecting the camera' test "$(count_of "$work/daemon-snap.log" 'connected')" = 1
check_not 'and it starts nothing' test "$(live_count)" -gt 0
ha_pub doorview/front-door-camera/live/set ON
check 'the stream after the big payload is still read correctly: ON works' wait_live 2 4
ha_pub doorview/front-door-camera/live/set OFF
sleep_s 1
check 'and the camera is still the same connection' test "$(count_of "$work/daemon-snap.log" 'connected')" = 1

echo '-- a motion picture while a view runs'
: > "$work/live.log"
before=$(snap_count)
ha_pub doorview/front-door-camera/live/set ON
sleep_s 1
rise
check 'the motion picture is published while the view runs' wait_snap "$((before + 1))" 9
sleep_s 1
check 'and the view goes on afterwards' wait_live 6 6
ha_pub doorview/front-door-camera/live/set OFF
sleep_s 1
check_not 'the sanitizers report nothing in the live run' grep -qE 'AddressSanitizer|runtime error' "$work/daemon-snap.log"
kill_daemon

echo '-- a retained ON is not a command'
ha_pub doorview/front-door-camera/live/set ON -r
: > "$work/live.log"
start_snap_daemon 1 'live=1\nlive_seconds=4\nlive_interval_ms=300'
sleep_s 3
check 'a retained ON that the broker hands over on subscribe starts nothing' test "$(live_count)" = 0
ha_pub doorview/front-door-camera/live/set '' -r
kill_daemon

echo '-- live off, and a camera that may not read the command topic'
start_snap_daemon 1
: > "$work/live.log"
ha_pub doorview/front-door-camera/live/set ON
sleep_s 2
check 'without live=1 an ON does nothing' test "$(live_count)" = 0
kill_daemon
# Mosquitto grants such a subscription (SUBACK QoS 0) and simply delivers nothing, so the camera cannot tell: a missing
# ACL line shows only as a view that never starts.
start_snap_daemon 1 "live=1\nuser=front-door-noread\npassword=$noread_password"
: > "$work/live.log"
ha_pub doorview/front-door-camera/live/set ON
sleep_s 2.5
check 'a camera whose broker user may not read the command topic gets no command' test "$(live_count)" = 0
check 'and it stays connected and running' sh -c "kill -0 '$daemon_pid' && test \"\$(grep -c connected '$work/daemon-snap.log')\" = 1"
kill_daemon
echo '-- Majestic gives nothing usable'
printf 'html' > "$work/mj/imgmode"
start_snap_daemon 1 'live=1\nlive_seconds=3\nlive_interval_ms=300'
: > "$work/live.log"
ha_pub doorview/front-door-camera/live/set ON
sleep_s 4.5
check 'no picture is published when Majestic answers with a page that is not a JPEG' test "$(live_count)" = 0
check 'it is logged once, not for every try' test "$(count_of "$work/daemon-snap.log" 'live view: no usable picture from Majestic')" = 1
check 'and the view still ends by itself' test "$(live_state)" = OFF
rm -f "$work/mj/imgmode"
kill_daemon
stop_live_subscribers
kill "$snap_sub_pid" 2> /dev/null
stop_majestic

echo '== sleep =='
# With sleep_after the camera goes to sleep like the factory firmware: it switches the PIR on (the mcu parameter of the
# syslink driver), syncs and writes 1 to the standby parameter. The parameters, the wake-up reason and the "stay awake"
# marker are plain files here. A PIR wake-up is reported as motion with a snapshot.
kill_daemon
make_jpeg 12000
start_majestic
set_mode normal
rm -f "$work/mj/imgmode" "$work/mj/reqs"
snap_total=0
set_total 0
: > "$work/snap.log"
kill "${snap_sub_pid:-}" 2> /dev/null
docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t 'doorview/front-door-camera/snapshot' -F '%r|%l|%x' >> "$work/snap.log" 2> /dev/null &
snap_sub_pid=$!
printf '6,300,1000000,-;doorview_power: command=a2 count=44 length=12 head=8a a2 01 01 00 00 0c 00 payload=02 00 63 00\n' > "$work/kmsg-battery"
printf '6,300,1000000,-;doorview_power: command=a2 count=44 length=12 head=8a a2 01 01 00 00 0c 00 payload=02 01 63 00\n' > "$work/kmsg-usb"
kill "$sub_pid" 2> /dev/null
sleep_log="$work/sleep-sub.log"
: > "$sleep_log"
docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t 'doorview/front-door-camera/motion' -t 'doorview/front-door-camera/availability' -F '%r|%t|%p' >> "$sleep_log" 2> /dev/null &
sub_pid=$!
sleep_s 0.5

start_sleep_daemon() { # <wake-up reason or ""> <kmsg file> [extra config lines, separated by \n]
    grep -qE 'AddressSanitizer|runtime error' "$work/daemon-sleep.log" 2> /dev/null && touch "$work/sleep-sanitizer"
    : > "$work/mcu"; : > "$work/standby"; : > "$work/reason"
    [ -z "$1" ] || printf '%s\n' "$1" > "$work/reason"
    : > "$sleep_log"
    { cat "$work/mqtt.conf"; printf 'kmsg=%s\nmotion=1\nmotion_port=%s\nmotion_hold=2\nsnapshot=1\nsnapshot_cooldown=1\nsleep_after=10\nreason_file=%s/reason\nmcu_parameter=%s/mcu\nstandby_parameter=%s/standby\nstay_awake_file=%s/stay\n%b\n' "$2" "$motion_port" "$work" "$work" "$work" "$work" "${3:-}"; } > "$work/mqtt-sleep.conf"
    "$work/doorview-mqtt-asan" "$work/mqtt-sleep.conf" > "$work/daemon-sleep.log" 2>&1 &
    daemon_pid=$!
}
sleeping() { [ "$(cat "$work/standby")" = 1 ]; }
wait_sleep() { # <seconds>
    for i in $(seq 1 "$(($1 * 10))"); do sleeping && return 0; sleep_s 0.1; done
    return 1
}

echo '-- a PIR wake-up is motion with a picture, then the camera sleeps again'
rm -f "$work/stay"
start_sleep_daemon pir "$work/kmsg-battery"
check 'the wake-up reason is logged' wait_for "$work/daemon-sleep.log" 'wake-up reason: pir' 5
check 'a PIR wake-up publishes motion ON' wait_for "$sleep_log" '|doorview/front-door-camera/motion|ON' 8
check 'and one picture' test "$(for i in $(seq 1 60); do [ "$(wc -l < "$work/snap.log" | tr -d ' ')" -ge 1 ] && echo 1 && break; sleep_s 0.1; done)" = 1
check 'the picture is the one Majestic served' test "$(tail -n 1 "$work/snap.log" | cut -d'|' -f3)" = "$(cat "$work/mj/img.hex")"
check 'the camera does not sleep while motion is still being reported' test "$(cat "$work/standby")" = ""
check 'after sleep_after seconds of nothing the standby is requested' wait_sleep 20
check 'the wake timer is switched off first (7b, four zero bytes) and then the PIR on (u16 1, as in the factory)' test "$(cat "$work/mcu")" = "$(printf '7b00000000\n780100')"
check 'Home Assistant is told that the camera is offline before it goes' wait_for "$sleep_log" '|doorview/front-door-camera/availability|offline' 3
check 'the log says that it is going to sleep' grep -q 'going to sleep' "$work/daemon-sleep.log"
check 'no second standby request in the first seconds' test "$(grep -c 'going to sleep' "$work/daemon-sleep.log")" = 1
kill_daemon

echo '-- a wake_timer asks the coprocessor to wake the camera after that many seconds (little endian)'
start_sleep_daemon pir "$work/kmsg-battery" 'wake_timer=21600'
check 'wake_timer=21600 is sent as 7b followed by 60 54 00 00' wait_sleep 20
check 'the timer comes before the PIR switch' test "$(cat "$work/mcu")" = "$(printf '7b60540000\n780100')"
kill_daemon

echo '-- wake_server and wake_pattern arm the keep-alive before the standby (docs/remote-wake.md)'
# The four commands for the wifi parameter: no authentication, the pattern in all four entries, one server, the start.
wake_expected=$(python3 - <<'PY'
p = bytearray(261); p[0] = 1
for e in range(4):
    p[1 + 65 * e:7 + 65 * e] = bytes.fromhex("a1b2c3d4e5f6"); p[65 + 65 * e] = 6
s = bytearray(293); s[0:5] = bytes([1, 1, 1, 45, 0]); s[5:9] = bytes([1, 8, 0xfb, 0x20])  # port 8443, little endian
s[9:13] = bytes([10, 0, 70, 202]); s[13:21] = b"doorview"
print("07\n2c" + p.hex() + "\n30" + s.hex() + "\n05")
PY
)
: > "$work/wifi"
start_sleep_daemon pir "$work/kmsg-battery" "wake_server=10.0.70.202:8443\nwake_pattern=A1B2C3D4E5F6\nwake_interval=45\nwifi_parameter=$work/wifi"
check 'the standby is still requested' wait_sleep 20
check 'the keep-alive was armed: 07, 2c with the pattern in all four entries, 30 with the server, 05' test "$(cat "$work/wifi")" = "$wake_expected"
check 'after the timer and the PIR, which go to the mcu parameter as before' test "$(cat "$work/mcu")" = "$(printf '7b00000000\n780100')"
check 'the log says so' grep -q 'wake-up from the network armed' "$work/daemon-sleep.log"
kill_daemon
start_sleep_daemon pir "$work/kmsg-battery" "wake_server=10.0.70.202:7967\nwake_pattern=a1b2c3d4e5f6\nwifi_parameter=$work/no-such-directory/wifi"
check 'a driver without the wifi parameter: the camera sleeps anyway' wait_sleep 20
check 'and the log says that the wake-up was refused' grep -q 'wake-up from the network refused' "$work/daemon-sleep.log"
kill_daemon
: > "$work/wifi"
start_sleep_daemon pir "$work/kmsg-battery"
check 'without wake_server nothing is armed' wait_sleep 20
check_not 'the wifi file stays empty' test -s "$work/wifi"
kill_daemon

echo '-- a wake-up from the network starts the live view by itself'
: > "$work/live-wake.log"
docker exec "$broker" mosquitto_sub -h 127.0.0.1 -u home-assistant -P "$ha_password" -t 'doorview/front-door-camera/live/state' -F '%r|%p' >> "$work/live-wake.log" 2> /dev/null &
live_wake_pid=$!
sleep_s 0.5
start_sleep_daemon wifi "$work/kmsg-battery" "live=1\nlive_seconds=3\nwake_server=10.0.70.202:7967\nwake_pattern=a1b2c3d4e5f6\nwifi_parameter=$work/wifi"
check 'the wake-up reason wifi is logged' wait_for "$work/daemon-sleep.log" 'wake-up reason: wifi' 5
check 'the live view starts without a command' wait_for "$work/live-wake.log" '|ON' 6
check 'and ends after live_seconds' wait_for "$work/live-wake.log" '|OFF' 8
check_not 'a wake-up from the network is not motion' grep -q '/motion|ON' "$sleep_log"
kill_daemon
start_sleep_daemon wifi "$work/kmsg-battery" "wake_server=10.0.70.202:7967\nwake_pattern=a1b2c3d4e5f6\nwifi_parameter=$work/wifi"
sleep_s 3
check_not 'without live=1 there is no live view' grep -q 'live view started' "$work/daemon-sleep.log"
kill_daemon
kill "$live_wake_pid" 2> /dev/null

echo '-- another wake-up reason: no motion, but the same sleep'
start_sleep_daemon poweron "$work/kmsg-battery"
check 'a power-on wake-up is logged' wait_for "$work/daemon-sleep.log" 'wake-up reason: poweron' 5
sleep_s 2
check_not 'it publishes no motion ON' grep -q '/motion|ON' "$sleep_log"
check 'it still sleeps after the idle time' wait_sleep 20
kill_daemon

echo '-- no wake-up reason file: a normal start'
start_sleep_daemon "" "$work/kmsg-battery"
sleep_s 2
check_not 'no motion is invented' grep -q '/motion|ON' "$sleep_log"
kill_daemon

echo '-- on a charger the camera stays awake unless sleep_usb=1'
start_sleep_daemon poweron "$work/kmsg-usb"
sleep_s 14
check_not 'it does not sleep on USB power' sleeping
check 'it says why' grep -q 'sleep postponed' "$work/daemon-sleep.log"
check_not 'it never switched the PIR on' test -s "$work/mcu"
kill_daemon
start_sleep_daemon poweron "$work/kmsg-usb" 'sleep_usb=1'
check 'sleep_usb=1 sleeps on USB power too' wait_sleep 20
kill_daemon

echo '-- the stay-awake marker keeps it up until it is removed'
: > "$work/stay"
start_sleep_daemon poweron "$work/kmsg-battery"
sleep_s 14
check_not 'with the marker it does not sleep' sleeping
rm -f "$work/stay"
check 'without it it sleeps' wait_sleep 8
kill_daemon

echo '-- a live view keeps the camera awake'
start_live_subscribers
start_sleep_daemon poweron "$work/kmsg-battery" 'live=1\nlive_seconds=30\nlive_interval_ms=300'
sleep_s 4
ha_pub doorview/front-door-camera/live/set ON
sleep_s 11
check_not 'still awake 15 s after the start: a running view is not idle, however long it lasts' sleeping
ha_pub doorview/front-door-camera/live/set OFF
sleep_s 1.5
check_not 'still awake right after the view ended: the end of the view counts as activity' sleeping
check 'it sleeps once the camera has been idle again for sleep_after seconds' wait_sleep 15
kill_daemon
stop_live_subscribers

echo '-- a standby that cannot be written does not kill the daemon'
start_sleep_daemon poweron "$work/kmsg-battery" "standby_parameter=$work/no-such-directory/standby"
check 'it logs that the standby was refused' wait_for "$work/daemon-sleep.log" 'sleep refused: cannot start the standby' 20
sleep_s 4
check 'the daemon is still running' kill -0 "$daemon_pid"
check 'and connected again (online is published after the offline)' test "$(grep -c 'availability|online' "$sleep_log")" -ge 2
kill_daemon
start_sleep_daemon poweron "$work/kmsg-battery" "mcu_parameter=$work/no-such-directory/mcu"
check 'a PIR switch that cannot be written stops the sleep before the standby' wait_for "$work/daemon-sleep.log" 'sleep refused: cannot switch the PIR on' 20
check_not 'and no standby is written' sleeping
kill_daemon

echo '== PIR motion =='
# With pir_motion=1 the PIR is the motion source while the camera is awake: the daemon switches it on (and sets the
# sensitivity), an alarm start in the kernel log is a motion edge with one snapshot, an alarm end is nothing, and with
# motion_video=0 Majestic's video detector is not polled at all.
kill_daemon
pir_seq=500
printf '6,300,1000000,-;doorview_power: command=a2 count=44 length=12 head=8a a2 01 01 00 00 0c 00 payload=02 00 63 00\n' > "$work/kmsg-pir"
printf '6,301,1000100,-;doorview_power: command=03 count=41 length=9 head=8a 03 01 01 00 00 09 00 payload=01\n' >> "$work/kmsg-pir"
pir_line() { # <01 = alarm start, 00 = alarm end>
    pir_seq=$((pir_seq + 1))
    printf '6,%d,%d,-;doorview_power: command=03 count=41 length=9 head=8a 03 01 01 00 00 09 00 payload=%s\n' "$pir_seq" "$((2000000 + pir_seq * 1000))" "$1" >> "$work/kmsg-pir"
}
start_pir_daemon() { # <extra config lines, separated by \n>
    : > "$work/mcu"; : > "$work/standby"; : > "$work/reason"; : > "$sleep_log"; : > "$work/snap.log"
    [ -z "${PIR_REASON:-}" ] || printf '%s\n' "$PIR_REASON" > "$work/reason"
    { cat "$work/mqtt.conf"; printf 'kmsg=%s/kmsg-pir\nmotion=1\nmotion_port=%s\nmotion_hold=2\nsnapshot=1\nsnapshot_cooldown=1\npir_motion=1\nmotion_video=0\nreason_file=%s/reason\nmcu_parameter=%s/mcu\nstandby_parameter=%s/standby\nstay_awake_file=%s/stay\n%b\n' "$work" "$motion_port" "$work" "$work" "$work" "$work" "${1:-}"; } > "$work/mqtt-pir.conf"
    "$work/doorview-mqtt-asan" "$work/mqtt-pir.conf" > "$work/daemon-pir.log" 2>&1 &
    daemon_pir_pid=$!
    daemon_pid=$daemon_pir_pid
}
snap_total_lines() { wc -l < "$work/snap.log" | tr -d ' '; }
hits_now() { wc -l < "$work/mj/hits" | tr -d ' '; }

echo '-- the PIR is switched on with the sensitivity, and an alarm in the history is ignored'
: > "$work/mj/hits"
hits_before=$(hits_now)
start_pir_daemon 'pir_sensitivity=2\nmotion_hold=3'
check 'the daemon says that the PIR is on' wait_for "$work/daemon-pir.log" 'PIR is on' 8
check 'the sensitivity is written first (level 2 in the high byte), then the PIR on' test "$(cat "$work/mcu")" = "$(printf '790002\n780100')"
sleep_s 2
check_not 'an alarm that is only in the replayed history is ignored' grep -q '/motion|ON' "$sleep_log"
check 'the motion state is OFF from the start' wait_for "$sleep_log" '|doorview/front-door-camera/motion|OFF' 5
check 'with motion_video=0 Majestic'"'"'s motion counter is never polled' test "$(hits_now)" = "$hits_before"

echo '-- an alarm start is a motion edge with one snapshot'
pir_line 01
check 'an alarm start publishes motion ON' wait_for "$sleep_log" '|doorview/front-door-camera/motion|ON' 6
check 'and one picture' test "$(for i in $(seq 1 60); do [ "$(snap_total_lines)" -ge 1 ] && echo 1 && break; sleep_s 0.1; done)" = 1
check 'the picture is the one Majestic served' test "$(tail -n 1 "$work/snap.log" | cut -d'|' -f3)" = "$(cat "$work/mj/img.hex")"
# Two more alarms, each inside the hold (3 s) of the one before: without the hold being extended the second one would
# arrive after the motion had ended and be a new edge.
sleep_s 1.5
pir_line 01
sleep_s 1.5
pir_line 01
sleep_s 1
check 'alarms inside the hold only extend it: no second ON' test "$(grep -c '/motion|ON' "$sleep_log")" = 1
check 'and no second picture' test "$(snap_total_lines)" = 1
pir_line 00
check 'an alarm end is not a motion start (no second ON)' test "$(grep -c '/motion|ON' "$sleep_log")" = 1
check 'motion goes OFF after the hold' test "$(for i in $(seq 1 60); do [ "$(grep -c '/motion|OFF' "$sleep_log")" -ge 2 ] && echo ok && break; sleep_s 0.1; done)" = ok
sleep_s 1.5
pir_line 01
check 'a second alarm after the hold is a new edge' test "$(for i in $(seq 1 60); do [ "$(grep -c '/motion|ON' "$sleep_log")" -ge 2 ] && echo ok && break; sleep_s 0.1; done)" = ok
check_not 'the sanitizers report nothing' grep -qE 'AddressSanitizer|runtime error' "$work/daemon-pir.log"
kill_daemon

echo '-- without pir_motion an alarm is only activity'
start_pir_daemon 'pir_motion=0'
sleep_s 2
pir_line 01
sleep_s 3
check_not 'no motion is reported' grep -q '/motion|ON' "$sleep_log"
check_not 'and the PIR is not switched on by the daemon' test -s "$work/mcu"
kill_daemon

echo '-- the sleep writes the timer, the sensitivity and the PIR again'
start_pir_daemon 'sleep_after=10\nsleep_usb=1\npir_sensitivity=5'
check 'it sleeps after the idle time' wait_sleep 25
check 'the writes are: sensitivity, PIR on (start), then timer off, sensitivity, PIR on (sleep)' test "$(cat "$work/mcu")" = "$(printf '790005\n780100\n7b00000000\n790005\n780100')"
kill_daemon

echo '-- a PIR wake-up: the picture first, then the PIR setup, even while Majestic is still starting'
# Earlier sections may have started more than one stand-in; none may answer now.
pkill -f "$work/fake-majestic.py" 2> /dev/null
majestic_pid=
sleep_s 0.5
PIR_REASON=pir start_pir_daemon 'pir_sensitivity=2\nsnapshot_delay_ms=0'
check 'the wake-up is reported as motion at once' wait_for "$sleep_log" '/motion|ON' 8
sleep_s 1.5
check 'no picture while Majestic does not answer' test "$(snap_total_lines)" = 0
check_not 'and the PIR is not set up before the picture' grep -q 'PIR is on' "$work/daemon-pir.log"
start_majestic
check 'the picture follows as soon as Majestic answers' test "$(for i in $(seq 1 80); do [ "$(snap_total_lines)" -ge 1 ] && echo 1 && break; sleep_s 0.1; done)" = 1
check 'the picture is the one Majestic served' test "$(tail -n 1 "$work/snap.log" | cut -d'|' -f3)" = "$(cat "$work/mj/img.hex")"
check 'Majestic not answering is logged once, not at every try' test "$(grep -c 'Majestic does not answer' "$work/daemon-pir.log")" = 1
check 'then the PIR is set up' wait_for "$work/daemon-pir.log" 'PIR is on' 5
check 'after the picture, not before' sh -c "awk '/snapshot published/ && !p {p=NR} /PIR is on/ && !q {q=NR} END {exit !(p && q && p < q)}' '$work/daemon-pir.log'"
check 'the setup writes the sensitivity and the PIR switch' test "$(cat "$work/mcu")" = "$(printf '790002\n780100')"
kill_daemon

echo '-- night_wait_ms: in the dark the wake-up picture waits for night mode'
set_night() { printf '%s' "$1" > "$work/mj/night"; }
set_night '0 -1 0'
PIR_REASON=pir start_pir_daemon 'snapshot_delay_ms=0\nnight_wait_ms=4000'
check 'it says that it waits' wait_for "$work/daemon-pir.log" 'waiting for night mode' 8
sleep_s 1
check 'no picture while the light is not measured' test "$(snap_total_lines)" = 0
set_night '0 22000 1'
sleep_s 0.8
check 'no picture while Majestic counts toward night' test "$(snap_total_lines)" = 0
set_night '1 22000 0'
check 'the picture follows once night mode is on' test "$(for i in $(seq 1 30); do [ "$(snap_total_lines)" -ge 1 ] && echo 1 && break; sleep_s 0.1; done)" = 1
check 'waiting is logged once for the picture' test "$(grep -c 'waiting for night mode' "$work/daemon-pir.log")" = 1
check_not 'and the wait did not run out' grep -q 'did not come in time' "$work/daemon-pir.log"
kill_daemon

echo '-- night_wait_ms: in daylight the picture does not wait'
set_night '0 2000 0'
PIR_REASON=pir start_pir_daemon 'snapshot_delay_ms=0\nnight_wait_ms=4000'
check 'the picture comes at once' test "$(for i in $(seq 1 30); do [ "$(snap_total_lines)" -ge 1 ] && echo 1 && break; sleep_s 0.1; done)" = 1
check_not 'and nothing waited' grep -q 'waiting for night mode' "$work/daemon-pir.log"
kill_daemon

echo '-- night_wait_ms: the wait is bounded'
set_night '0 -1 0'
PIR_REASON=pir start_pir_daemon 'snapshot_delay_ms=0\nnight_wait_ms=1500'
check 'it waits' wait_for "$work/daemon-pir.log" 'waiting for night mode' 8
check 'the picture comes anyway when the wait runs out' test "$(for i in $(seq 1 40); do [ "$(snap_total_lines)" -ge 1 ] && echo 1 && break; sleep_s 0.1; done)" = 1
check 'and the log says so' grep -q 'night mode did not come in time' "$work/daemon-pir.log"
kill_daemon

echo '-- night_wait_ms: a Majestic without night metrics does not hold the picture'
rm -f "$work/mj/night"
PIR_REASON=pir start_pir_daemon 'snapshot_delay_ms=0\nnight_wait_ms=4000'
check 'the picture comes at once' test "$(for i in $(seq 1 30); do [ "$(snap_total_lines)" -ge 1 ] && echo 1 && break; sleep_s 0.1; done)" = 1
check_not 'and nothing waited' grep -q 'waiting for night mode' "$work/daemon-pir.log"
kill_daemon
PIR_REASON=

echo '== configuration =='
# The daemon exits with 2 when the configuration is refused and, on a host without a readable kernel log (the test
# gives it a missing path), with 3 once the configuration has been accepted. Any other non-zero exit would also
# "fail", so the tests insist on the exact code.
config_exit() { # <printf format of the config lines>
    printf "$1" > "$work/cfg.conf"
    printf 'kmsg=%s/no-such-kmsg\n' "$work" >> "$work/cfg.conf"
    "$work/doorview-mqtt" "$work/cfg.conf" > /dev/null 2>&1
    echo $?
}
check 'a plain valid configuration is accepted' test "$(config_exit 'host=127.0.0.1\n')" = 3
check 'missing host is rejected' test "$(config_exit 'user=x\n')" = 2
check 'bad host is rejected' test "$(config_exit 'host=not-an-ip\n')" = 2
check 'node names with a slash are rejected' test "$(config_exit 'host=127.0.0.1\nnode=a/b\n')" = 2
check 'a missing config file is rejected' test "$("$work/doorview-mqtt" "$work/does-not-exist.conf" > /dev/null 2>&1; echo $?)" = 2
check 'a motion port of 0 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion_port=0\n')" = 2
check 'a motion port above 65535 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion_port=70000\n')" = 2
check 'a motion hold of 0 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion_hold=0\n')" = 2
check 'a motion hold above 600 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion_hold=601\n')" = 2
check 'a valid motion and snapshot configuration is accepted' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_cooldown=60\n')" = 3
check 'snapshot=1 without motion=1 is rejected' test "$(config_exit 'host=127.0.0.1\nsnapshot=1\n')" = 2
check 'a snapshot path with a space is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_path=/image.jpg HTTP/1.1\n')" = 2
check 'a snapshot path with a carriage return is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_path=/a\rX: y\n')" = 2
check 'a snapshot path must start with a slash' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_path=image.jpg\n')" = 2
check 'a snapshot path with a query string is accepted' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_path=/image.jpg?width=640&height=360\n')" = 3
check 'a snapshot cooldown of 0 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_cooldown=0\n')" = 2
check 'a motion_min_rate of 0 and of 10000 are accepted' test "$(config_exit 'host=127.0.0.1\nmotion_min_rate=0\n')$(config_exit 'host=127.0.0.1\nmotion_min_rate=10000\n')" = 33
check 'a motion_min_rate above 10000 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion_min_rate=10001\n')" = 2
check 'a negative motion_min_rate is rejected' test "$(config_exit 'host=127.0.0.1\nmotion_min_rate=-1\n')" = 2
check 'a motion_window of 1 and of 10 are accepted' test "$(config_exit 'host=127.0.0.1\nmotion_window=1\n')$(config_exit 'host=127.0.0.1\nmotion_window=10\n')" = 33
check 'a motion_window of 0 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion_window=0\n')" = 2
check 'a motion_window of 11 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion_window=11\n')" = 2
check 'a snapshot_delay_ms of 0 and of 5000 are accepted' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_delay_ms=0\n')$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_delay_ms=5000\n')" = 33
check 'a snapshot_delay_ms above 5000 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_delay_ms=5001\n')" = 2
check 'a negative snapshot_delay_ms is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_delay_ms=-5\n')" = 2
check 'live_seconds 1 and 300 are accepted' test "$(config_exit 'host=127.0.0.1\nlive_seconds=1\n')$(config_exit 'host=127.0.0.1\nlive_seconds=300\n')" = 33
check 'live_seconds 0 and 301 are rejected' test "$(config_exit 'host=127.0.0.1\nlive_seconds=0\n')$(config_exit 'host=127.0.0.1\nlive_seconds=301\n')" = 22
check 'live_interval_ms 100 and 5000 are accepted' test "$(config_exit 'host=127.0.0.1\nlive_interval_ms=100\n')$(config_exit 'host=127.0.0.1\nlive_interval_ms=5000\n')" = 33
check 'live_interval_ms 99 and 5001 are rejected' test "$(config_exit 'host=127.0.0.1\nlive_interval_ms=99\n')$(config_exit 'host=127.0.0.1\nlive_interval_ms=5001\n')" = 22
check 'a live_path with a space is rejected' test "$(config_exit 'host=127.0.0.1\nlive_path=/image.jpg HTTP/1.1\n')" = 2
check 'a live_path with a query string is accepted' test "$(config_exit 'host=127.0.0.1\nlive_path=/image.jpg?width=320&height=180&qfactor=30\n')" = 3
check 'a snapshot cooldown above 3600 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsnapshot_cooldown=3601\n')" = 2


echo '== wifi_reboot =='
reboot_case() { # <broker port> <rx: frozen|moving> <wifi_reboot value> <seconds to wait> [restart the broker after this many seconds]; prints the daemon exit code, or "running"
    echo 1000 > "$work/rx_packets"
    { cat "$work/mqtt.conf"; printf 'port=%s\nrx_stats=%s/rx_packets\nwifi_reboot=%s\n' "$1" "$work" "$3"; } > "$work/mqtt-reboot.conf"
    if [ "$2" = moving ]; then
        ( n=1000; while :; do n=$((n + 1)); echo $n > "$work/rx_packets"; sleep 1; done ) &
        mover=$!
    fi
    "$work/doorview-mqtt-asan" "$work/mqtt-reboot.conf" > "$work/daemon-reboot.log" 2>&1 &
    reboot_pid=$!
    begin=$(date +%s)
    end=$((begin + $4))
    restarted=0
    while [ "$(date +%s)" -lt "$end" ]; do
        kill -0 $reboot_pid 2> /dev/null || break
        if [ -n "${5:-}" ] && [ "$restarted" = 0 ] && [ "$(date +%s)" -ge $((begin + $5)) ]; then
            restarted=1
            docker restart "$broker" > /dev/null 2>&1
        fi
        sleep 0.2
    done
    if kill -0 $reboot_pid 2> /dev/null; then
        kill $reboot_pid 2> /dev/null
        wait $reboot_pid 2> /dev/null
        echo running
    else
        wait $reboot_pid
        echo $?
    fi
    [ -z "${mover:-}" ] || { kill $mover 2> /dev/null; wait $mover 2> /dev/null; mover=; }
}
check 'a frozen packet counter with the broker unreachable restarts the camera' test "$(reboot_case 1 frozen 2 25)" = 86
check 'and the log says why' grep -q 'wifi data path is dead' "$work/daemon-reboot.log"
check 'it does not restart before four times the time has passed since the start' test "$(reboot_case 1 frozen 2 6)" = running
check 'a moving packet counter does not restart it' test "$(reboot_case 1 moving 2 20)" = running
check 'a reachable broker does not restart it, even with a frozen counter' test "$(reboot_case "$port" frozen 2 20)" = running
check 'a short broker outage with a frozen counter does not restart it (the broker must be unreachable for the whole time)' test "$(reboot_case "$port" frozen 8 46 34)" = running
check 'wifi_reboot=0 (the default) never restarts it' test "$(reboot_case 1 frozen 0 20)" = running
check_not 'the sanitizers report nothing with wifi_reboot' grep -qE 'AddressSanitizer|runtime error' "$work/daemon-reboot.log"
check 'wifi_reboot 0 and 3600 are accepted' test "$(config_exit 'host=127.0.0.1\nwifi_reboot=0\n')$(config_exit 'host=127.0.0.1\nwifi_reboot=3600\n')" = 33
check 'wifi_reboot above 3600 and negative are rejected' test "$(config_exit 'host=127.0.0.1\nwifi_reboot=3601\n')$(config_exit 'host=127.0.0.1\nwifi_reboot=-1\n')" = 22
check 'motion_settle 0 and 600 are accepted' test "$(config_exit 'host=127.0.0.1\nmotion_settle=0\n')$(config_exit 'host=127.0.0.1\nmotion_settle=600\n')" = 33
check 'motion_settle above 600 and negative are rejected' test "$(config_exit 'host=127.0.0.1\nmotion_settle=601\n')$(config_exit 'host=127.0.0.1\nmotion_settle=-1\n')" = 22

grep -qE 'AddressSanitizer|runtime error' "$work/daemon-sleep.log" 2> /dev/null && touch "$work/sleep-sanitizer"
check_not 'the sanitizers report nothing during the sleep tests' test -e "$work/sleep-sanitizer"

check 'pir_sensitivity above 5 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\npir_motion=1\npir_sensitivity=6\n')" = 2
check 'night_wait_ms above 8000 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nnight_wait_ms=8001\n')" = 2
check 'night_wait_ms=3000 is accepted' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nnight_wait_ms=3000\n')" = 3
check 'pir_sensitivity 5, the factory high level, is accepted' test "$(config_exit 'host=127.0.0.1\nmotion=1\npir_motion=1\nmotion_video=0\npir_sensitivity=5\n')" = 3
check 'pir_motion without motion=1 is rejected' test "$(config_exit 'host=127.0.0.1\npir_motion=1\n')" = 2
check 'a valid PIR configuration is accepted' test "$(config_exit 'host=127.0.0.1\nmotion=1\npir_motion=1\nmotion_video=0\npir_sensitivity=2\n')" = 3

echo '-- configuration of the sleep keys'
check 'sleep_after below 10 seconds is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=5\n')" = 2
check 'sleep_after above 3600 seconds is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=4000\n')" = 2
check 'sleep_after without snapshot=1 is rejected' test "$(config_exit 'host=127.0.0.1\nsleep_after=60\n')" = 2
check 'a valid sleep configuration is accepted' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nsleep_usb=1\n')" = 3
check 'sleep_after=0 means off and is accepted without a snapshot' test "$(config_exit 'host=127.0.0.1\nsleep_after=0\n')" = 3
check 'a parameter path must be a clean absolute path' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nstandby_parameter=/a b\n')" = 2
check 'wake_timer above a week is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_timer=604801\n')" = 2
check 'wake_timer 0 and a week are accepted' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_timer=0\n')$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_timer=604800\n')" = 33
check 'wake_server needs a port' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_server=10.0.70.202\nwake_pattern=a1b2c3d4e5f6\n')" = 2
check 'wake_server port 0 is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_server=10.0.70.202:0\nwake_pattern=a1b2c3d4e5f6\n')" = 2
check 'wake_pattern must be 12 hex digits' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_server=10.0.70.202:7967\nwake_pattern=a1b2c3d4e5\n')$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_server=10.0.70.202:7967\nwake_pattern=a1b2c3d4e5f6a7\n')$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_server=10.0.70.202:7967\nwake_pattern=a1b2c3d4e5fg\n')" = 222
check 'wake_server without wake_pattern, or the other way round, is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_server=10.0.70.202:7967\n')$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_pattern=a1b2c3d4e5f6\n')" = 22
check 'a wake-up server needs the sleep' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nwake_server=10.0.70.202:7967\nwake_pattern=a1b2c3d4e5f6\n')" = 2
check 'wake_interval 10 to 3600' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_server=10.0.70.202:7967\nwake_pattern=a1b2c3d4e5f6\nwake_interval=9\n')$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_server=10.0.70.202:7967\nwake_pattern=a1b2c3d4e5f6\nwake_interval=3600\n')" = 23
check 'a complete wake-up configuration is accepted' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nwake_server=10.0.70.202:7967\nwake_pattern=A1b2C3d4E5f6\n')" = 3
check 'a relative parameter path is rejected' test "$(config_exit 'host=127.0.0.1\nmotion=1\nsnapshot=1\nsleep_after=60\nmcu_parameter=mcu\n')" = 2

echo "passed=$passed failed=$failed"
[ "$failed" = 0 ]
