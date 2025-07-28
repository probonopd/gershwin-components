#!/bin/sh

# Check for 'import' command
if ! command -v import >/dev/null 2>&1; then
    echo "Error: 'import' command not found. Please install ImageMagick (pkg install ImageMagick)."
    exit 1
fi

# Determine filename
DIR="$HOME/Desktop"
BASE="Screenshot"
EXT="png"
FILE="$DIR/$BASE.$EXT"
i=1

while [ -e "$FILE" ]; do
    FILE="$DIR/$BASE-$i.$EXT"
    i=$((i + 1))
done

# Get active window id
WIN_ID=$(xprop -root | awk '/_NET_ACTIVE_WINDOW\(WINDOW\)/{print $NF}')

if [ -z "$WIN_ID" ]; then
    echo "Error: Could not determine active window."
    exit 1
fi

# Take screenshot
import -window "$WIN_ID" "$FILE"

echo "Screenshot saved to $FILE"