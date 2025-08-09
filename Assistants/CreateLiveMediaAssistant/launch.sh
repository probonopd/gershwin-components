#!/bin/sh

# Launch script for Create Live Media Assistant
# For testing purposes

echo "Starting Create Live Media Assistant..."
cd "$(dirname "$0")"
exec ./CreateLiveMediaAssistant.app/CreateLiveMediaAssistant "$@"
