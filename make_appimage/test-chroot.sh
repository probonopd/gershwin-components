#!/bin/sh
#
# test-chroot.sh -- Run an AppImage inside a near-empty chroot to verify
#                   that no host system libraries are needed.
#
# Usage:  sudo ./test-chroot.sh <AppImage>
#
# Creates a temporary directory with only the bare minimum (no libraries,
# no /usr, no /etc) and runs the AppImage inside a chroot.  If the AppImage
# works, every dependency is truly self-contained.

set -eu

APPIMAGE="${1:-}"
if [ ! -f "$APPIMAGE" ] || [ ! -x "$APPIMAGE" ]; then
    echo "Usage: $0 <AppImage>" >&2
    echo "Note: must be run as root (chroot requires privileges)" >&2
    exit 1
fi

APPIMAGE="$(realpath "$APPIMAGE")"
CHROOT="$(mktemp -d "/tmp/chroot-$$.XXXXXX")"

cleanup() {
    rc=$?
    umount "$CHROOT/proc" 2>/dev/null || true
    rm -rf "$CHROOT"
    exit $rc
}
trap cleanup EXIT INT TERM

# Minimal chroot — nothing but /dev, /tmp, and a shell (AppRun needs it).
mkdir -p "$CHROOT/dev" "$CHROOT/tmp" "$CHROOT/proc" "$CHROOT/sys" "$CHROOT/bin"

# /bin/sh — the AppRun script and extracted runtime need a shell.
# Use a static copy if available, otherwise the dynamic one (which will
# fail to link inside the chroot — that's OK, it tells us the AppImage
# isn't truly standalone).
if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" "$CHROOT/bin/busybox" 2>/dev/null || true
    ln -sf busybox "$CHROOT/bin/sh" 2>/dev/null || true
else
    cp /bin/sh "$CHROOT/bin/sh" 2>/dev/null || true
fi

# /dev/null — required by virtually everything
mknod "$CHROOT/dev/null" c 1 3 2>/dev/null || true
chmod 666 "$CHROOT/dev/null" 2>/dev/null || true

# /dev/urandom — needed by some libc operations
mknod "$CHROOT/dev/urandom" c 1 9 2>/dev/null || true

# Mount proc so the AppRun binary can read /proc/self/exe to find its path
mount -t proc none "$CHROOT/proc" 2>/dev/null || true

echo "============================================"
echo " Running in minimal chroot: $CHROOT"
echo " App: $(basename "$APPIMAGE")"
echo "============================================"

# Extract the AppImage on the host, then copy the AppDir into the chroot.
# This avoids needing FUSE or the AppImage runtime inside the chroot.
EXTRACT_DIR="$(mktemp -d "/tmp/appimage-extract-$$.XXXXXX")"
"$APPIMAGE" --appimage-extract >/dev/null 2>&1 || true
if [ -d squashfs-root ]; then
    mv squashfs-root "$CHROOT/tmp/AppDir"
else
    echo "ERROR: could not extract AppImage" >&2
    rm -rf "$EXTRACT_DIR"
    exit 1
fi
rm -rf "$EXTRACT_DIR"

set +e
chroot "$CHROOT" /tmp/AppDir/AppRun 2>&1
RC=$?
set -e

echo "============================================"
if [ $RC -eq 0 ]; then
    echo " SUCCESS: AppImage exit code $RC"
else
    echo " FAILURE: AppImage exit code $RC"
fi
echo "============================================"
exit $RC
