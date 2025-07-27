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

print_step() {
  echo "[build.sh] $1"
}

print_step "Configuring pkg repository"
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
print_step "Updating package repository"
pkg update -f

build_package()
{
  PORT=$1
  print_step "Installing build dependencies for $PORT"
  # Use -r to use repository only, never build from source
  ( cd "${PORT}" && make build-depends-list | cut -c 12- | xargs pkg install -y -r ) || {
    print_step "Warning: Some dependencies for $PORT could not be installed from packages"
  }
  print_step "Generating checksum for $PORT"
  make -C "${PORT}" makesum
  print_step "Packaging $PORT"
  make -C "${PORT}" package
}

print_step "Configuring ports tree overlay"
echo "OVERLAYS=$(readlink -f .)/ports/portstree" >> /etc/make.conf
print_step "Changing directory to /usr/ports"
# cd /usr/ports
cd ports/portstree || {
  print_step "Error: Could not change directory to ports/portstree"
  exit 1
}

print_step "Finding all ports to build"
PORTS=$(find "${HERE}" -type d -depth 3 | awk -F/ '{print $(NF-1) "/" $NF}') # Last two components of the path
for PORT in ${PORTS}; do
    print_step "Building package for $PORT"
    build_package "${PORT}"
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
print_step "Creating repository metadata for $ABI"
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
