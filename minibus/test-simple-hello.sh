#!/bin/bash

echo "Testing MiniBus Hello reply capture..."

# Clean up
pkill -f minibus || true
rm -f /tmp/minibus-hello-test

# Start MiniBus
./obj/minibus /tmp/minibus-hello-test > hello-test-daemon.log 2>&1 &
DAEMON_PID=$!
sleep 2

echo "MiniBus started with PID $DAEMON_PID"

# Test with dbus-send
echo "Sending Hello with dbus-send..."
timeout 5 dbus-send --address="unix:path=/tmp/minibus-hello-test" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames > hello-test-output.log 2>&1

echo "dbus-send result: $?"
echo "Output:"
cat hello-test-output.log

echo "Daemon log:"
cat hello-test-daemon.log

# Clean up
kill $DAEMON_PID 2>/dev/null || true
rm -f /tmp/minibus-hello-test
