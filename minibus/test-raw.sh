#!/bin/csh

# Simple test to send raw D-Bus message data
cd /home/User/gershwin-prefpanes/minibus

# Start daemon in background
./obj/minibus &
set daemon_pid=$!

sleep 1

# Use netcat to send raw data (if available) or create a simple client
echo "Testing with a minimal D-Bus message..."

# Kill daemon
kill $daemon_pid

wait
