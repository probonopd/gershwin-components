#!/bin/sh
#
# Launch script for Bhyve Assistant
#

cd "$(dirname "$0")"

echo "Starting Bhyve Virtual Machine Assistant..."

# Check if we're on FreeBSD
if ! uname -s | grep -q "FreeBSD"; then
    echo "Warning: This assistant is designed for FreeBSD systems with bhyve support."
    echo "You may experience limited functionality on other operating systems."
fi

# Launch the assistant
exec ./BhyveAssistant.app/BhyveAssistant "$@"
