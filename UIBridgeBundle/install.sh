#!/bin/sh
# Install UIBridge.bundle and enable it as an AppKit user bundle.
# Run the install step as root (it writes under /System).
set -e

. /System/Library/Makefiles/GNUstep.sh

gmake
echo ">> installing UIBridge.bundle (needs root for /System)..."
gmake install

echo ">> enabling autoload via GSAppKitUserBundles (per-user)"
defaults write NSGlobalDomain GSAppKitUserBundles '(UIBridge)'

echo "Done. Restart GNUstep apps to pick up the bundle."
echo "For a system-wide enable, add UIBridge to GSAppKitUserBundles in"
echo "/System/Library/Preferences/GlobalDefaults/ instead."
