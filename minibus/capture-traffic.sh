#!/bin/sh

# Capture all traffic from dbus-send to understand the exact sequence
echo "=== Capturing dbus-send Traffic ==="

# Clean up
pkill -f minibus 2>/dev/null
rm -f /tmp/minibus-socket daemon.log traffic.log

echo "1. Starting MiniBus daemon..."
timeout 30 ./obj/minibus > daemon.log 2>&1 &
DAEMON_PID=$!
sleep 1

if [ ! -S /tmp/minibus-socket ]; then
    echo "ERROR: Socket not created"
    exit 1
fi

echo "2. Using socat to proxy and capture traffic..."
# Start socat in background to capture traffic
socat -v UNIX-LISTEN:/tmp/proxy-socket,fork UNIX-CONNECT:/tmp/minibus-socket 2>traffic.log &
SOCAT_PID=$!
sleep 1

echo "3. Running dbus-send through the proxy..."
timeout 10 dbus-send --bus=unix:path=/tmp/proxy-socket \
    --dest=org.freedesktop.DBus \
    --type=method_call \
    /org/freedesktop/DBus \
    org.freedesktop.DBus.ListNames 2>&1

echo "4. Stopping proxy and daemon..."
kill $SOCAT_PID 2>/dev/null
kill $DAEMON_PID 2>/dev/null
wait

echo "5. Analyzing traffic..."
echo "--- Traffic Log ---"
cat traffic.log | head -50

echo "6. Analyzing daemon log..."
echo "--- Daemon Log ---"
grep -E "(Hello|ListNames|NameAcquired|NameOwner|processMessage|Broken pipe|Connection closed)" daemon.log

echo "=== Analysis complete ==="
