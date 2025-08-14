#!/bin/bash
# Build and run ZFS test

echo "Building ZFS test program..."
clang19 -o test_zfs test_zfs.m BAZFSUtility.m \
    -I. \
    -framework Foundation \
    -lobjc \
    -Wall -Wno-nullability-completeness

if [ $? -eq 0 ]; then
    echo "Build successful, running test..."
    echo "Note: Test requires sudo for ZFS operations"
    sudo ./test_zfs
else
    echo "Build failed!"
    exit 1
fi
