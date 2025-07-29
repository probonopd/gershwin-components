#!/bin/bash

echo "Testing MiniBus with dbus-monitor first..."

# Clean up
pkill -f minibus || true
rm -f /tmp/minibus-monitor-test

# Start MiniBus
./obj/minibus /tmp/minibus-monitor-test > monitor-daemon.log 2>&1 &
DAEMON_PID=$!
sleep 2

echo "MiniBus started with PID $DAEMON_PID"

# Test with dbus-monitor
echo "Testing dbus-monitor..."
timeout 5 dbus-monitor --address="unix:path=/tmp/minibus-monitor-test" > monitor-output.log 2>&1 &
MONITOR_PID=$!
sleep 3

kill $MONITOR_PID 2>/dev/null || true

echo "Monitor output:"
cat monitor-output.log

echo "Daemon log:"
cat monitor-daemon.log

# Clean up
kill $DAEMON_PID 2>/dev/null || true
rm -f /tmp/minibus-monitor-test
