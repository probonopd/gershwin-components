#!/bin/bash

echo "=== Starting dbus-daemon ==="
dbus-daemon --session --address=unix:path=/tmp/dbus-test.socket --print-address --nofork > dbus-daemon-2.log 2>&1 &
DAEMON_PID=$!
sleep 2

echo "=== Testing MiniBus client with socat proxy ==="
# Start proxy to capture MiniBus client traffic
timeout 30 socat -x -v unix-listen:/tmp/dbus-proxy.socket,reuseaddr unix-connect:/tmp/dbus-test.socket > minibus-capture.log 2>&1 &
PROXY_PID=$!
sleep 1

echo "=== Running MiniBus test-real-dbus through proxy ==="
DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus-proxy.socket timeout 10 ./obj/test-real-dbus > minibus-client.log 2>&1

echo "=== Cleanup ==="
kill $PROXY_PID 2>/dev/null || true
kill $DAEMON_PID 2>/dev/null || true
sleep 1

echo "=== Results ==="
echo "MiniBus traffic capture:"
cat minibus-capture.log
echo
echo "MiniBus client log:"
cat minibus-client.log
echo
echo "Daemon log:"
cat dbus-daemon-2.log
