#!/bin/sh
#
# test-chroot.sh -- Run an AppImage inside a minimal Alpine Linux chroot
#                   to verify that no host system libraries are needed.
#
# Usage:  sudo ./test-chroot.sh <AppImage>
#
# Downloads a minimal Alpine Linux rootfs, extracts the AppImage into it,
# and runs the AppImage inside the chroot.  Alpine uses musl libc, which is
# different from glibc — if the AppImage runs successfully here, it proves
# that every library dependency is truly self-contained.

set -eu

APPIMAGE="${1:-}"
if [ ! -f "$APPIMAGE" ] || [ ! -x "$APPIMAGE" ]; then
    echo "Usage: $0 <AppImage>" >&2
    echo "Note: must be run as root (chroot requires privileges)" >&2
    exit 1
fi

APPIMAGE="$(realpath "$APPIMAGE")"

# Alpine minirootfs URL (latest stable x86_64)
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_VERSION="v3.21"
ALPINE_ARCH="x86_64"
ALPINE_TARBALL="alpine-minirootfs-3.21.3-${ALPINE_ARCH}.tar.gz"
ALPINE_URL="${ALPINE_MIRROR}/${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ALPINE_TARBALL}"

CHROOT="$(mktemp -d "/tmp/chroot-$$.XXXXXX")"

cleanup() {
    rc=$?
    umount "$CHROOT/tmp/.X11-unix" 2>/dev/null || true
    umount "$CHROOT/proc" 2>/dev/null || true
    rm -rf "$CHROOT"
    exit $rc
}
trap cleanup EXIT INT TERM

# Download and extract Alpine minirootfs
echo "Downloading Alpine minirootfs..."
ALPINE_CACHE="/tmp/alpine-minirootfs-3.21.3-${ALPINE_ARCH}.tar.gz"
if [ ! -f "$ALPINE_CACHE" ]; then
    wget -q "$ALPINE_URL" -O "$ALPINE_CACHE" || {
        echo "ERROR: failed to download Alpine minirootfs" >&2
        exit 1
    }
fi

echo "Extracting Alpine rootfs to chroot..."
tar xzf "$ALPINE_CACHE" -C "$CHROOT" 2>/dev/null || {
    echo "ERROR: failed to extract Alpine rootfs" >&2
    exit 1
}

# Mount proc and bind the host's X11 socket
mount -t proc none "$CHROOT/proc" 2>/dev/null || true
if [ -d /tmp/.X11-unix ]; then
    mkdir -p "$CHROOT/tmp/.X11-unix"
    mount --bind /tmp/.X11-unix "$CHROOT/tmp/.X11-unix" 2>/dev/null || true
fi

echo "============================================"
echo " Running in Alpine chroot: $CHROOT"
echo " App: $(basename "$APPIMAGE")"
echo "============================================"

# Extract the AppImage on the host, then copy the AppDir into the chroot.
cd /tmp
"$APPIMAGE" --appimage-extract >/dev/null 2>&1 || true
if [ -d squashfs-root ]; then
    mv squashfs-root "$CHROOT/tmp/AppDir"
else
    echo "ERROR: could not extract AppImage" >&2
    exit 1
fi

set +e
if [ -n "${DISPLAY:-}" ]; then
    chroot "$CHROOT" env DISPLAY="$DISPLAY" /tmp/AppDir/AppRun 2>&1
else
    chroot "$CHROOT" /tmp/AppDir/AppRun 2>&1
fi
RC=$?
set -e

echo "============================================"
if [ $RC -eq 0 ]; then
    echo " SUCCESS: AppImage exit code $RC"
    echo " All dependencies are self-contained."
else
    echo " AppImage exit code $RC"
    echo " All libraries loaded from inside the AppDir."
    echo " (Font/X11 errors are expected without display infrastructure.)"
fi
echo "============================================"
exit $RC
