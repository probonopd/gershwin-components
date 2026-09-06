#!/bin/sh
# Build whisper.cpp with GPU (Vulkan) support on Debian, Arch, FreeBSD, OpenBSD
set -eu

: "${REPO:=https://github.com/ggml-org/whisper.cpp}"
: "${BRANCH:=master}"
: "${PREFIX:=/usr/local}"
: "${JOBS:=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

detect_os() {
    case "$(uname -s)" in
        Linux)
            if [ -f /etc/debian_version ]; then echo debian
            elif [ -f /etc/arch-release ]; then echo arch
            else echo linux; fi
            ;;
        FreeBSD) echo freebsd ;;
        OpenBSD) echo openbsd ;;
        *) echo unknown ;;
    esac
}

install_deps() {
    os=$1
    echo "==> Installing dependencies for $os..."

    case $os in
        debian)
            sudo apt-get update -qq
            sudo apt-get install -y -qq \
                git build-essential cmake patchelf \
                libvulkan-dev mesa-vulkan-drivers \
                libasound2-dev
            ;;
        arch)
            sudo pacman -Sy --noconfirm \
                git base-devel cmake \
                vulkan-devel vulkan-intel \
                alsa-lib
            ;;
        freebsd)
            sudo pkg install -y \
                git cmake patchelf \
                vulkan-loader vulkan-headers \
                alsa-lib
            ;;
        openbsd)
            doas pkg_add \
                git cmake patchelf \
                vulkan-loader
            ;;
        *)
            echo "Unsupported OS: $os"
            echo "Install git, cmake, a C++ compiler, Vulkan SDK, and ALSA manually."
            ;;
    esac
}

build_whisper() {
    tmpdir=$(mktemp -d /tmp/whisper-build-XXXXXX)
    echo "==> Cloning whisper.cpp into $tmpdir"
    git clone --depth=1 -b "$BRANCH" "$REPO" "$tmpdir"

    cd "$tmpdir"
    echo "==> Configuring with Vulkan GPU support"
    if cmake -B build -S . \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_VULKAN=ON \
        -DGGML_CUDA=OFF \
        -DGGML_METAL=OFF \
        -DGGML_SYCL=OFF 2>/dev/null; then
        echo "==> Vulkan enabled"
    else
        echo "==> Vulkan not available, falling back to CPU-only"
        cmake -B build -S . \
            -DCMAKE_BUILD_TYPE=Release \
            -DGGML_VULKAN=OFF \
            -DGGML_CUDA=OFF \
            -DGGML_METAL=OFF \
            -DGGML_SYCL=OFF
    fi

    echo "==> Building (${JOBS} jobs)"
    cmake --build build -j "$JOBS"

    echo "==> Installing to ${PREFIX}"
    sudo cmake --install build --prefix "$PREFIX"

    echo "==> Updating shared-library cache"
    case $(uname -s) in
        Linux) sudo ldconfig ;;
        FreeBSD) sudo ldconfig -m "$PREFIX/lib" ;;
        OpenBSD) doas ldconfig "$PREFIX/lib" ;;
    esac

    # Replace relative NEEDED paths (../bin/, ../../bin/) with plain names
    # so the dynamic linker can find them via the standard library path.
    if command -v patchelf >/dev/null 2>&1; then
        echo "==> Fixing library NEEDED entries with patchelf"
        for lib in "$PREFIX/lib"/libwhisper* "$PREFIX/lib"/libggml* \
                   "$PREFIX/bin"/whisper* "$PREFIX/bin"/ggml*; do
            [ -f "$lib" ] || continue
            for needed in $(patchelf --print-needed "$lib" 2>/dev/null | \
                            grep '\.\./bin/'); do
                base=$(basename "$needed")
                echo "  $lib: $needed -> $base"
                patchelf --replace-needed "$needed" "$base" "$lib" 2>/dev/null || \
                sudo patchelf --replace-needed "$needed" "$base" "$lib"
            done
        done
    fi

    echo "==> Cleaning up"
    rm -rf "$tmpdir"

    echo ""
    echo "Done. Verify with:"
    echo "  whisper-cli --help 2>&1 | grep -i gpu"
}

os=$(detect_os)
install_deps "$os"
build_whisper
