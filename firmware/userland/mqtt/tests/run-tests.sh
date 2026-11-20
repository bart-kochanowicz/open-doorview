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
mkdir -p "$work/broker"
cat > "$work/broker/mosquitto.conf" << EOF
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
acl_file /mosquitto/config/acl
persistence false
EOF
cat > "$work/broker/acl" << 'EOF'
user home-assistant
topic readwrite #

user front-door-camera
topic write doorview/front-door-camera/#
topic write homeassistant/sensor/front-door-camera/+/config
topic write homeassistant/binary_sensor/front-door-camera/+/config
topic write homeassistant/event/front-door-camera/+/config
EOF
: > "$work/broker/passwd"
docker run --rm -v "$work/broker:/mosquitto/config" eclipse-mosquitto:2 sh -c \
    "mosquitto_passwd -b /mosquitto/config/passwd home-assistant '$ha_password' && mosquitto_passwd -b /mosquitto/config/passwd front-door-camera '$camera_password'" > /dev/null 2>&1
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
def serve(conn):
    try:
        conn.recv(4096)
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
kill_daemon
wait_for "$work/sub.log" '|doorview/front-door-camera/availability|offline' 12

echo '== configuration =='
check_not 'missing host is rejected' sh -c "printf 'user=x\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'bad host is rejected' sh -c "printf 'host=not-an-ip\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'node names with a slash are rejected' sh -c "printf 'host=127.0.0.1\nnode=a/b\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'a motion port of 0 is rejected' sh -c "printf 'host=127.0.0.1\nmotion_port=0\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'a motion port above 65535 is rejected' sh -c "printf 'host=127.0.0.1\nmotion_port=70000\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'a motion hold of 0 is rejected' sh -c "printf 'host=127.0.0.1\nmotion_hold=0\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'a motion hold above 600 is rejected' sh -c "printf 'host=127.0.0.1\nmotion_hold=601\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'a missing config file is rejected' "$work/doorview-mqtt" "$work/does-not-exist.conf"

echo "passed=$passed failed=$failed"
[ "$failed" = 0 ]
