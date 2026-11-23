#!/bin/sh
# Runs every suite that does not need a camera. The MQTT daemon suite needs Docker and is skipped without it.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
failed=0

run() {
    echo "=== $1 ==="
    if ! sh "$here/$1"; then
        failed=1
    fi
}

run firmware/stage1-wifi/tests/run-tests.sh
run firmware/stage2-lcd/tests/run-tests.sh
run firmware/stage3-mqtt/tests/run-tests.sh
run firmware/stage4-sleep/tests/run-tests.sh
run firmware/stage5-sleep-daemon/tests/run-tests.sh
run firmware/stage6-wake-timer/tests/run-tests.sh
run tools/tests/run-tests.sh
if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
    run firmware/userland/mqtt/tests/run-tests.sh
else
    echo "=== firmware/userland/mqtt/tests/run-tests.sh: skipped (Docker is not available) ==="
fi

[ "$failed" -eq 0 ] && echo 'all suites passed' || echo 'SOME SUITES FAILED'
exit "$failed"
