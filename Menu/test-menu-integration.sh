#!/bin/sh
# Test script to run Menu.app and Chrome in the same DBus session

echo "Starting new DBus session..."
eval `dbus-launch --sh-syntax`
echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
echo "DBUS_SESSION_BUS_PID=$DBUS_SESSION_BUS_PID"

cd /home/User/gershwin-components/Menu

echo "Starting Menu.app..."
timeout 60 ./Menu.app/Menu &
MENU_PID=$!

echo "Waiting for Menu.app to start..."
sleep 3

echo "Starting Chrome with DBus menu support..."
timeout 30 chrome --new-window http://example.com &
CHROME_PID=$!

echo "Menu.app PID: $MENU_PID"
echo "Chrome PID: $CHROME_PID"

echo "Waiting for Chrome to register menus..."
sleep 10

echo "Terminating processes..."
kill $CHROME_PID 2>/dev/null
kill $MENU_PID 2>/dev/null

echo "Cleaning up DBus session..."
kill $DBUS_SESSION_BUS_PID 2>/dev/null

echo "Test completed."
