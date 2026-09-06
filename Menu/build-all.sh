#!/bin/bash
# Build Menu.app and its menu extra bundles

set -e

cd "$(dirname "$0")"

echo "Building Menu application..."
make all

echo ""
echo "==================================="
echo "Build complete!"
echo "==================================="
echo ""
echo "Menu.app: ./Menu.app"
echo "Bundles: ./MenuExtras/*/ (built via 'make install')"
