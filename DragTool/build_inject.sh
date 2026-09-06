#!/bin/sh
# Build DragInject.so - only depends on libobjc + POSIX, no AppKit/Foundation.

set -e

SRCDIR="$(dirname "$0")"
OUTPUT="${1:-$SRCDIR/DragInject.so}"

echo "Compiling DragInject.so (minimal deps: libobjc only)..."
clang -shared -o "$OUTPUT" "$SRCDIR/DragInject.m" \
  -I/System/Library/Headers \
  -DGNUSTEP -DGNUSTEP_RUNTIME=1 -D_NONFRAGILE_ABI=1 \
  -fno-strict-aliasing -pthread -fPIC \
  -Wall -Wextra -Wno-import \
  -g -O2 \
  -fobjc-runtime=gnustep-2.2 -fblocks \
  -fconstant-string-class=NSConstantString \
  -L/System/Library/Libraries \
  -l:libobjc.so.4.6 -lm

echo "Built: $OUTPUT"
ls -la "$OUTPUT"
echo ""
echo "Dependencies:"
ldd "$OUTPUT" | grep -E '=>|not found' || echo "(none)"
