#!/bin/bash

# Capture exactly what happens during Hello exchange

echo "=== Starting dbus-daemon with debug logging ==="
dbus-daemon --session --address=unix:path=/tmp/dbus-test.socket --print-address --nofork > dbus-daemon.log 2>&1 &
DAEMON_PID=$!
sleep 2

echo "=== Testing Hello exchange with socat proxy ==="
# Start proxy to capture traffic
timeout 30 socat -x -v unix-listen:/tmp/dbus-proxy.socket,reuseaddr unix-connect:/tmp/dbus-test.socket > hello-capture.log 2>&1 &
PROXY_PID=$!
sleep 1

echo "=== Sending Hello through proxy ==="
DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus-proxy.socket timeout 10 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello > hello-reply.log 2>&1

echo "=== Cleanup ==="
kill $PROXY_PID 2>/dev/null || true
kill $DAEMON_PID 2>/dev/null || true
sleep 1

echo "=== Results ==="
echo "Hello exchange capture:"
cat hello-capture.log
echo
echo "Hello reply:"
cat hello-reply.log
echo
echo "Daemon log:"
cat dbus-daemon.log
