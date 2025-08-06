#!/bin/sh
# install-gershwin.sh - Install Gershwin desktop environment
# This script installs Gershwin packages from the custom repository

set -e

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Starting Gershwin installation..."

# Ensure we're running as root
if [ "$(id -u)" -ne 0 ]; then
    log "Error: This script must be run as root"
    exit 1
fi

# Bootstrap pkg if needed
log "Bootstrapping pkg..."
ASSUME_ALWAYS_YES=yes pkg bootstrap -f

# Install basic dependencies first
log "Installing basic dependencies..."
pkg install -y git-lite gmake

# Configure Gershwin repository
log "Configuring Gershwin repository..."
cat > /usr/local/etc/pkg/repos/Gershwin.conf <<'EOF'
Gershwin: {
  url: "https://api.cirrus-ci.com/v1/artifact/github/gershwin-desktop/gershwin-unstable-ports/data/packages/FreeBSD:14:amd64",
  mirror_type: "http",
  enabled: yes
}
EOF

# Update package database
log "Updating package database..."
pkg update

# Install Gershwin desktop environment
log "Installing Gershwin desktop environment..."
pkg install -y gershwin-desktop

# Source GNUstep environment
log "Setting up GNUstep environment..."
if [ -f /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh ]; then
    . /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
    log "GNUstep environment sourced successfully"
else
    log "Warning: GNUstep.sh not found, manual environment setup may be required"
fi

log "Gershwin installation completed successfully!"