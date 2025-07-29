#!/bin/bash

# Test D-Bus authentication manually
SOCKET="/tmp/test-dbus-socket3"

# Start daemon in background
echo "Starting daemon..."
./obj/minibus "$SOCKET" &
DAEMON_PID=$!

sleep 1

# Test manual authentication
echo "Testing manual authentication..."
(
  # Send credentials passing nul byte first
  printf '\0'
  
  # Send AUTH command
  printf 'AUTH EXTERNAL 31303031\r\n'
  
  # Send BEGIN command after getting OK response
  printf 'BEGIN\r\n'
  
  # Give daemon a moment to process
  sleep 0.1
  
  # Try to send a simple D-Bus Hello message
  # This is a simplified Hello message in binary format
  # endian(l) + type(1) + flags(0) + version(1) + body_length(0) + serial(1) + header_length(X) + header_fields + body
  printf 'l\001\000\001\000\000\000\000\001\000\000\000\000\000\000\000'
  
) | timeout 5 nc -U "$SOCKET" | xxd

echo "Stopping daemon..."
kill $DAEMON_PID 2>/dev/null
wait $DAEMON_PID 2>/dev/null

echo "Test complete"
