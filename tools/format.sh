#!/bin/sh
# Formats the C sources with clang-format (style in .clang-format), in a Docker image of its own.
# Usage: tools/format.sh            rewrite the files in place
#        tools/format.sh --check    change nothing; fail and name the files that are not formatted
# Formatting must not change a binary: run tools/build.sh afterwards, every tested binary must stay identical.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
mode=${1:-}
case "$mode" in
    '' | --check) ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

files=$(cd "$repo" && git ls-files 'firmware/*.c' 'firmware/*.h')
[ -n "$files" ] || exit 0
docker build -q -t open-doorview-format "$here/format" > /dev/null
if [ "$mode" = --check ]; then
    # shellcheck disable=SC2086 # the list is split on purpose
    docker run --rm -v "$repo":/repo:ro -w /repo open-doorview-format clang-format --dry-run -Werror $files
else
    # shellcheck disable=SC2086
    docker run --rm -v "$repo":/repo -w /repo open-doorview-format clang-format -i $files
fi
