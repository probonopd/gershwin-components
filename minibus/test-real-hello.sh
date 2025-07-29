#!/bin/bash

echo "Testing real dbus-daemon Hello exchange..."

# Clean up any existing processes
pkill -f "dbus-daemon --session" || true
sleep 1

# Create a test session bus
export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/test-real-hello-socket"
dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --nofork &
DAEMON_PID=$!
sleep 2

echo "Real daemon started with PID $DAEMON_PID"

# Test with dbus-send and capture output
echo "Testing dbus-send..."
timeout 5 dbus-send --address="$DBUS_SESSION_BUS_ADDRESS" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames > real-hello-test.log 2>&1

# Check the result
if [ $? -eq 0 ]; then
    echo "✓ Real daemon test successful"
    cat real-hello-test.log
else
    echo "✗ Real daemon test failed"
    cat real-hello-test.log
fi

# Clean up
kill $DAEMON_PID 2>/dev/null || true
rm -f /tmp/test-real-hello-socket
