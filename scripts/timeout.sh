#!/bin/bash
# Timeout wrapper for macOS (timeout command not available by default)
# Usage: ./scripts/timeout.sh <seconds> <command> [args...]

if [ $# -lt 2 ]; then
    echo "Usage: $0 <seconds> <command> [args...]"
    exit 1
fi

TIMEOUT=$1
shift

# Run command in background (properly handle all arguments)
"$@" &
CMD_PID=$!

# Wait for timeout or command completion
(
    sleep $TIMEOUT
    if kill -0 $CMD_PID 2>/dev/null; then
        echo "⏱️  Command timed out after ${TIMEOUT}s, killing process $CMD_PID"
        kill -TERM $CMD_PID 2>/dev/null
        sleep 1
        kill -KILL $CMD_PID 2>/dev/null
        exit 124
    fi
) &
TIMEOUT_PID=$!

# Wait for command to finish
wait $CMD_PID
EXIT_CODE=$?

# Kill timeout watcher
kill $TIMEOUT_PID 2>/dev/null
wait $TIMEOUT_PID 2>/dev/null

exit $EXIT_CODE

