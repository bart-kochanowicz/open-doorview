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

# Every stage, in order (stage1-wifi, stage2-lcd, ..., stage13-night-wait).
for suite in $(cd "$here" && ls -d firmware/stage*/tests/run-tests.sh | sort -V); do
    run "$suite"
done
run tools/tests/run-tests.sh
if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
    run firmware/userland/mqtt/tests/run-tests.sh
    echo "=== tools/format.sh --check ==="
    sh "$here/tools/format.sh" --check || failed=1
else
    echo "=== firmware/userland/mqtt/tests/run-tests.sh and tools/format.sh --check: skipped (Docker is not available) ==="
fi

[ "$failed" -eq 0 ] && echo 'all suites passed' || echo 'SOME SUITES FAILED'
exit "$failed"
