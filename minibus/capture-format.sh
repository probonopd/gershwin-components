#!/bin/bash
# Compare message formats between dbus-send and our client

echo "=== Message Format Comparison Test ==="

# Start fresh D-Bus daemon
pkill -f 'dbus-daemon --session' 2>/dev/null || true
sleep 1

dbus-daemon --session --fork --print-address > /tmp/real-dbus-address 2>/dev/null
DBUS_ADDRESS=$(cat /tmp/real-dbus-address)
SOCKET_PATH=$(echo $DBUS_ADDRESS | sed 's/.*path=\([^,]*\).*/\1/')

echo "D-Bus daemon started at: $DBUS_ADDRESS"
echo "Socket path: $SOCKET_PATH"

# Use socat to proxy and capture traffic
echo "Starting traffic capture proxy..."

# Create a FIFO for logging
mkfifo /tmp/dbus-capture.log

# Start socat to proxy and log traffic
(
echo "Starting socat proxy..."
socat -x -v UNIX-LISTEN:/tmp/dbus-proxy,fork UNIX-CONNECT:$SOCKET_PATH 2>&1 | tee /tmp/dbus-capture.log &
SOCAT_PID=$!
echo "Socat PID: $SOCAT_PID"

sleep 1

echo "Testing dbus-send through proxy..."
export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/dbus-proxy"
timeout 5 dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1 || echo "dbus-send completed"

sleep 1
kill $SOCAT_PID 2>/dev/null
) &

sleep 8

echo "Stopping proxy and analyzing capture..."
pkill -f socat || true
rm -f /tmp/dbus-proxy /tmp/dbus-capture.log

echo "Now testing our client directly..."
cd /home/User/gershwin-prefpanes/minibus
timeout 5 ./obj/simple-format-test $SOCKET_PATH 2>&1 | head -10

echo "Cleaning up..."
pkill -f 'dbus-daemon --session' 2>/dev/null || true
