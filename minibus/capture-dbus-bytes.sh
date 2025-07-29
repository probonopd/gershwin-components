#!/bin/bash

# Capture the exact bytes from dbus-send using socat
# We'll create a proxy that logs all traffic

SOCKET_DIR="/tmp/dbus-capture"
REAL_SOCKET="/run/user/$UID/bus"
PROXY_SOCKET="$SOCKET_DIR/bus"

mkdir -p "$SOCKET_DIR"

# Kill any existing socat process
pkill -f "socat.*dbus-capture" || true

# Start socat proxy that logs traffic to files
socat -v UNIX-LISTEN:"$PROXY_SOCKET",fork,reuseaddr UNIX-CONNECT:"$REAL_SOCKET" > "$SOCKET_DIR/traffic.log" 2>&1 &
SOCAT_PID=$!

echo "Proxy started with PID $SOCAT_PID"
sleep 1

# Set DBUS_SESSION_BUS_ADDRESS to use our proxy
export DBUS_SESSION_BUS_ADDRESS="unix:path=$PROXY_SOCKET"

# Send a message through the proxy
echo "Sending ListNames through proxy..."
timeout 10 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames

# Clean up
kill $SOCAT_PID 2>/dev/null || true

echo "Traffic log:"
cat "$SOCKET_DIR/traffic.log"
