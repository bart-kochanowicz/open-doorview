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
topic write homeassistant/+/front-door-camera/+/config
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

echo '== configuration =='
check_not 'missing host is rejected' sh -c "printf 'user=x\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'bad host is rejected' sh -c "printf 'host=not-an-ip\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'node names with a slash are rejected' sh -c "printf 'host=127.0.0.1\nnode=a/b\n' > '$work/bad.conf'; '$work/doorview-mqtt' '$work/bad.conf'"
check_not 'a missing config file is rejected' "$work/doorview-mqtt" "$work/does-not-exist.conf"

echo "passed=$passed failed=$failed"
[ "$failed" = 0 ]
