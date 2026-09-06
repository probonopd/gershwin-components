#!/bin/bash
# find-gnustep-app.sh - Validate a GitHub repo as a GNUstep app and generate a Catalog.plist entry
#
# Usage:
#   ./find-gnustep-app.sh <owner/repo> [display-name]
#
# Example:
#   ./find-gnustep-app.sh anthonyc-r/Clock
#   ./find-gnustep-app.sh onflapp/gs-terminal "Terminal (onflapp)"
#
# The script clones the repo, checks for a valid GNUmakefile with APP_NAME,
# checks for AppKit imports, and outputs a plist dict block for Catalog.plist.
# If the makefile is in a subdirectory (e.g., repo/SubDir/GNUmakefile), the
# script outputs a MakefilePath key.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <owner/repo> [display-name]" >&2
    exit 1
fi

REPO="$1"
REPO_URL="https://github.com/$REPO"
DISPLAY_NAME="${2:-$(basename "$REPO" .app)}"
TMPDIR=$(mktemp -d /tmp/gnustep-scan-XXXXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Cloning $REPO_URL ..." >&2
git clone --depth=1 --quiet "$REPO_URL" "$TMPDIR/repo" 2>&1 || {
    echo "Error: failed to clone $REPO_URL" >&2
    exit 1
}

# Find all GNUmakefiles (exclude obj/ and .app dirs)
MAKEFILES=$(find "$TMPDIR/repo" -name 'GNUmakefile' -o -name 'GNUmakefile.in' \
    | grep -v '/obj/' | grep -v '\.app/' || true)

if [ -z "$MAKEFILES" ]; then
    echo "Error: no GNUmakefile found in $REPO" >&2
    exit 1
fi

# Find the best makefile (prefer one with APP_NAME, prefer root over subdir)
BEST_MF=""
for mf in $MAKEFILES; do
    if grep -q '^APP_NAME' "$mf" 2>/dev/null; then
        BEST_MF="$mf"
        break
    fi
done

if [ -z "$BEST_MF" ]; then
    # Fallback: first GNUmakefile found
    BEST_MF=$(echo "$MAKEFILES" | head -1)
fi

if ! grep -q '^APP_NAME' "$BEST_MF" 2>/dev/null; then
    echo "Error: no APP_NAME found in $BEST_MF" >&2
    exit 1
fi

# Determine if app uses AppKit (check .m files for AppKit import)
HAS_APPKIT=0
DIR=$(dirname "$BEST_MF")
if grep -rls '#import.*<AppKit' "$DIR" --include='*.m' 2>/dev/null | head -1 >/dev/null; then
    HAS_APPKIT=1
elif grep -rls '@interface.*:.*NSWindowController\|@interface.*:.*NSView\|@interface.*:.*NSDocument' "$DIR" --include='*.m' 2>/dev/null | head -1 >/dev/null; then
    HAS_APPKIT=1
fi

if [ "$HAS_APPKIT" -eq 0 ]; then
    echo "Warning: no AppKit usage found in .m files (may not be a GUI app)" >&2
fi

# Determine makefile path relative to repo root
REL_MF="${BEST_MF#$TMPDIR/repo/}"
REL_MF="${REL_MF#/}"

# Extract description from makefile comment or GitHub description
DESC=$(grep -m1 '^# ' "$BEST_MF" 2>/dev/null | sed 's/^# *//' || true)
if [ -z "$DESC" ]; then
    DESC="$DISPLAY_NAME app"
fi

# Output plist dict
echo "  <dict>"
echo "    <key>Name</key>"
echo "    <string>$DISPLAY_NAME</string>"
echo "    <key>GitURL</key>"
echo "    <string>$REPO_URL</string>"
echo "    <key>Description</key>"
echo "    <string>$DESC</string>"
if [ "$REL_MF" != "GNUmakefile" ] && [ "$REL_MF" != "GNUmakefile.in" ]; then
    echo "    <key>MakefilePath</key>"
    echo "    <string>$REL_MF</string>"
fi
echo "  </dict>"

echo "--- OK: $DISPLAY_NAME (makefile=$REL_MF, appkit=$HAS_APPKIT)" >&2
