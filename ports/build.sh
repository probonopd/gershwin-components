#!/bin/sh

set -e

build_package()
{
  PORT=$1
  ( cd "${PORT}" && make build-depends-list | cut -c 12- | xargs pkg install -y ) 
  make -C "${PORT}" package
}

# TODO: Replace with a more robust solution to overlay the ports tree that doesn't require a unionfs mount
mount -t unionfs $(readlink -f .) /usr/ports
HERE="${PWD}"
cd /usr/ports

# Build all ports in the current directory
HERE=$(dirname "$(readlink -f "$0")")
PORTS=$(find ${HERE} -type d -depth 2 | cut -d "/" -f 2-99)
for PORT in ${PORTS}; do
  if [ -d "${PORT}" ]; then
    build_package "${PORT}"
  fi
done
cd "${HERE}"
umount /usr/ports

# FreeBSD repository
ABI=$(pkg config abi) # E.g., FreeBSD:13:amd64
mkdir -p "${ABI}"
find . -name '*.pkg' -exec mv {} "${ABI}/" \;
pkg repo "${ABI}/"
# index.html for the FreeBSD repository
cd "${ABI}/"
echo "<html><ul>" > index.html
find . -depth 1 -exec echo '<li><a href="{}" download>{}</a></li>' \; | sed -e 's|\./||g' >> index.html
echo "</ul></html>" >> index.html
cd -