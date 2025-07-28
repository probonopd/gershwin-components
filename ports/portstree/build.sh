#!/bin/sh
# Automated build and plist generation for FreeBSD port
set -e

PORTDIR="$(dirname "$0")"
PORTNAME="gershwin-globalshortcuts"

cd "$PORTDIR/sysutils/$PORTNAME"

# Clean previous build
make clean

# Build and stage
make stage

# Generate plist automatically
make makeplist > pkg-plist

# Build package
make package

# Optionally, clean up after packaging
make clean

echo "Build and packaging complete."
