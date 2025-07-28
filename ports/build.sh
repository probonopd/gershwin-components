#!/bin/sh

# Copyright (c) 2025, Simon Peter
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

set -e

HERE=$(dirname "$(readlink -f "$0")")

export CC=clang
export CXX=clang++

print_step() {
  echo "[build.sh] $1"
}

# Function to generate version from date like Gershwin does
# This is possibly not how it should be done according to FreeBSD ports guidelines,
# but it is a simple way to ensure each build has a unique version for now.
generate_version() {
  VERSION=$(date +%Y%m%d%H%M)
  echo "$VERSION"
}

print_step "Configuring pkg repository"
if [ ! -f /usr/local/etc/pkg/repos/FreeBSD.conf ]; then
  mkdir -p /usr/local/etc/pkg/repos
  cat > /usr/local/etc/pkg/repos/FreeBSD.conf << 'EOF'
FreeBSD: {
  url: "pkg+http://pkg.FreeBSD.org/${ABI}/quarterly",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF
fi
print_step "Updating package repository"
pkg update -f

build_package()
{
  PORT=$(echo "$1" | awk -F'/' '{print $(NF-1) "/" $NF}') # Two last path elements

  print_step "=========================="
  print_step "Building package for $PORT"
  print_step ""

  cd "${HERE}/portstree/${PORT}" || {
    print_step "Error: Could not change directory to $PORT"
    return 1
  }

  # Set SNAPDATE for version generation
  SNAPDATE=$(generate_version)
  print_step "Using SNAPDATE: $SNAPDATE"
  export SNAPDATE

  make clean
  rm -f pkg-plist

  print_step "Downloading sources for $PORT"
  make fetch

  print_step "Generating checksum for $PORT"
  make makesum

  print_step "Building $PORT"
  make build BATCH=yes
  if [ $? -ne 0 ]; then
    print_step "Error: Build failed for $PORT"
    return 1
  fi

  print_step "Installing to staging area for $PORT"
  make stage BATCH=yes
  if [ $? -ne 0 ]; then
    print_step "Error: Staging failed for $PORT"
    return 1
  fi

  print_step "Generating plist for $PORT"
  make makeplist | tail -n +2 > pkg-plist || {
    print_step "Error: Failed to generate plist for $PORT"
    return 1
  }
  # find "$PORT/work/stage" | sed "s|$PORT/work/stage/||" > pkg-plist

  print_step "Packaging $PORT"
  make package BATCH=yes || {
    print_step "Error: Packaging failed for $PORT"
    return 1
  }
  print_step "Package for $PORT built successfully"
  
  ls "${HERE}/portstree/${PORT}"/work/pkg/*.pkg || {
    print_step "Error: No package files found for $PORT"
    return 1
  }
  # List contents of the package file(s)
  for pkg_file in "${HERE}/portstree/${PORT}"/work/pkg/*.pkg; do
    print_step "Contents of package file: $pkg_file"
    tar -tzf "$pkg_file" || {
      print_step "Error: Failed to list contents of package file $pkg_file"
      return 1
    }
  done

  print_step "=========================="
  return 0
}

print_step "Configuring ports tree overlay"
echo "OVERLAYS=${HERE}/portstree" >> /etc/make.conf
print_step "Changing directory to portstree"
# cd /usr/ports
cd "${HERE}/portstree" || {
  print_step "Error: Could not change directory to portstree"
  exit 1
}

# Install all dependencies before building ports


print_step "Installing dependencies for all ports"

for PORT in $(find ${HERE} -depth 4 -type f -name Makefile | xargs dirname); do
  if [ -f "${PORT}/Makefile" ]; then
    print_step "Checking dependencies for ${PORT}"
    ( cd "${PORT}" && make build-depends-list 2>/dev/null | sort | uniq | cut -d '/' -f 4- | xargs pkg install -y ) || {
      print_step "Warning: Could not install dependencies for ${PORT}"
    }
    print_step "Building package for $PORT"
    build_package "${PORT}" || {
      print_step "Error: Failed to build package for ${PORT}"
      exit 1
    }
  fi
done

print_step "Returning to $HERE"
cd "${HERE}"
print_step "Cleaning up make.conf"
sed -i.bak '/^OVERLAYS=/d' /etc/make.conf

print_step "Configuring FreeBSD repository"
ABI=$(pkg config abi) # E.g., FreeBSD:13:amd64
mkdir -p "${ABI}"
print_step "Moving all .pkg files to $ABI directory"
find . -name '*.pkg' -exec mv {} "${ABI}/" \;
print_step "Creating repositBATCH=yes ory metadata for $ABI"
pkg repo "${ABI}/"
# index.html for the FreeBSD repository
print_step "Generating index.html for repository"
cd "${ABI}/"
echo "<html><ul>" > index.html
find . -depth 1 -exec echo '<li><a href="{}" download>{}</a></li>' \; | sed -e 's|\./||g' >> index.html
echo "</ul></html>" >> index.html
cd -

print_step "Moving repository directory to parent of $HERE"
mv "${ABI}" "${HERE}/../"
