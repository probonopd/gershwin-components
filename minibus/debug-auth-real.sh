#!/bin/bash
# Debug authentication with real D-Bus daemon step by step

echo "Starting fresh D-Bus daemon..."
pkill -f 'dbus-daemon --session' 2>/dev/null || true
sleep 1

dbus-daemon --session --fork --print-address > /tmp/real-dbus-address 2>/dev/null
DBUS_ADDRESS=$(cat /tmp/real-dbus-address)
SOCKET_PATH=$(echo $DBUS_ADDRESS | sed 's/.*path=\([^,]*\).*/\1/')

echo "D-Bus daemon started at: $DBUS_ADDRESS"
echo "Socket path: $SOCKET_PATH"

echo "Testing with socat to see raw authentication..."

# Create a test that shows what the real daemon expects
(
echo "Sending initial null byte + AUTH command..."
# Send null byte first, then AUTH command
printf '\0AUTH EXTERNAL 31303031\r\n' | timeout 5 socat - UNIX-CONNECT:$SOCKET_PATH 2>/dev/null
) &

sleep 0.5

echo "Now testing with netcat style..."
(
echo "Using printf to send exact bytes..."
printf '\0AUTH EXTERNAL 31303031\r\nBEGIN\r\n' | timeout 3 nc -U $SOCKET_PATH 2>/dev/null || echo "nc failed"
) &

sleep 0.5

echo "Done with manual tests."
echo "Now testing our client with debug..."

cd /home/User/gershwin-prefpanes/minibus
echo "Testing our client:"
timeout 5 ./obj/minibus-test $SOCKET_PATH

echo "Cleaning up..."
pkill -f 'dbus-daemon --session' 2>/dev/null || true
