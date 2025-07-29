#!/bin/bash

# Capture real dbus-daemon ListNames reply to analyze the exact format
DBUS_ADDRESS="unix:path=/tmp/dbus-P1nOzmniC5,guid=a87110e01e80e212aa6d511368892a37"

echo "Testing with real dbus-daemon..."
export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS"

# Get the exact bytes that a real dbus-daemon sends
echo "Sending ListNames to real daemon..."
timeout 5 dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply / org.freedesktop.DBus.ListNames > real-listnames-output.txt 2>&1

echo "Real daemon output:"
cat real-listnames-output.txt
