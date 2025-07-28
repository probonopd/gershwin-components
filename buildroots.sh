#!/bin/sh
# Build all projects and package them into tar.zst archives

# Projects to build
PROJECTS="BootEnvironments Display GlobalShortcuts StartupDisk LoginWindow globalshortcutsd"

# If GNUSTEP_MAKEFILES is not set, source GNUstep.sh to set it up
if [ -z "$GNUSTEP_MAKEFILES" ]; then
    . /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
fi

export CC=clang
export OBJC=clang
export OBJCXX=clang++
export CXX=clang++

HERE="$(dirname "$(readlink -f "$0")")"

echo "Building all preference panes and tools..."

# Install build dependencies
echo "Installing build dependencies..."
sudo pkg install -y gnustep-make gnustep-base gnustep-gui gnustep-back gmake || {
    echo "Error: Failed to install build dependencies"
    exit 1
}
echo "Build dependencies installed successfully"
echo ""

# Ensure we're in the base directory
cd "$HERE"

SUCCESS_COUNT=0
FAIL_COUNT=0

for PROJECT in $PROJECTS; do
    echo "Building $PROJECT..."
    
    # Check if project directory exists
    if [ ! -d "$HERE/$PROJECT" ]; then
        echo "Warning: Directory $PROJECT does not exist in $HERE, skipping..."
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    
    cd "$HERE/$PROJECT"
    
    # Clean any existing root directory
    if [ -d root ]; then
        rm -rf root
    fi
    
    # Build and install with DESTDIR (continue on error)
    if gmake install DESTDIR=root; then
        # Create tar.zst archive if root directory exists
        if [ -d root ]; then
            echo "Creating ${PROJECT}.tar.zst..."
            (cd root && tar --zstd -cf "../${PROJECT}.tar.zst" .)
            echo "Created ${PROJECT}.tar.zst"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "Warning: No root directory created for $PROJECT"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "Error: Failed to build $PROJECT"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    
    echo "Finished $PROJECT"
    echo ""
done

echo "Build summary:"
echo "  Successful: $SUCCESS_COUNT"
echo "  Failed: $FAIL_COUNT"
echo ""

# Create out directory and collect all zst files
echo "Collecting archives into out/ directory..."
mkdir -p "$HERE/out"

COLLECTED_COUNT=0
for PROJECT in $PROJECTS; do
    if [ -f "$HERE/$PROJECT/${PROJECT}.tar.zst" ]; then
        echo "  Copying ${PROJECT}.tar.zst to out/"
        cp "$HERE/$PROJECT/${PROJECT}.tar.zst" "$HERE/out/"
        COLLECTED_COUNT=$((COLLECTED_COUNT + 1))
    fi
done

echo ""
echo "Archives collected in out/ directory: $COLLECTED_COUNT"
if [ "$COLLECTED_COUNT" -gt 0 ]; then
    echo "Contents of out/:"
    ls -la "$HERE/out/"*.tar.zst 2>/dev/null | while read -r line; do
        echo "  $line"
    done
fi