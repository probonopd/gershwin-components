#!/bin/sh
# Builds and runs the DiskUtility Wave-1 unit test suite, prints per-tool
# PASS counts and exits nonzero when any assertion fails or a tool crashes.

# No set -u: GNUstep.sh probes ZSH_VERSION and friends unguarded.

cd "$(dirname "$0")" || exit 2

if [ -f /System/Library/Makefiles/GNUstep.sh ]; then
    # shellcheck disable=SC1091
    . /System/Library/Makefiles/GNUstep.sh
fi

TOOLS="t_Parsing t_PartitionLayout t_Models t_MockBackend"

gmake || exit 2

status=0
for tool in $TOOLS; do
    binary="./obj/$tool"
    if [ ! -x "$binary" ]; then
        echo "$tool: MISSING BINARY"
        status=1
        continue
    fi
    output=$("$binary" 2>&1)
    code=$?
    passed=$(printf '%s\n' "$output" | grep -c '^Passed test:')
    failed=$(printf '%s\n' "$output" | grep -c '^Failed test:')
    crashed=$(printf '%s\n' "$output" | grep -c 'Uncaught exception')
    echo "$tool: $passed passed, $failed failed, $crashed uncaught"
    if [ "$failed" -ne 0 ] || [ "$crashed" -ne 0 ] || [ "$code" -ne 0 ]; then
        printf '%s\n' "$output" | grep -E '^Failed test:|Uncaught exception'
        status=1
    fi
done

exit $status
