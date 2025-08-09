#!/bin/sh
#
# Build script for Debian Runtime Installer Assistant
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo "${GREEN}Building Debian Runtime Installer Assistant${NC}"
echo "=============================================="

# Check if we're in the right directory
if [ ! -f "DebianRuntimeInstaller.m" ]; then
    echo "${RED}Error: Please run this script from the DebianRuntimeInstaller directory${NC}"
    exit 1
fi

# Check for required tools
echo "${YELLOW}Checking build tools...${NC}"
command -v gmake >/dev/null 2>&1 || { echo "${RED}Error: gmake is required but not installed${NC}"; exit 1; }
command -v clang19 >/dev/null 2>&1 || { echo "${RED}Error: clang19 is required but not installed${NC}"; exit 1; }

# Clean previous build
echo "${YELLOW}Cleaning previous build...${NC}"
gmake clean 2>/dev/null || true

# Build the framework first
echo "${YELLOW}Building GSAssistantFramework...${NC}"
cd ../Framework
gmake clean 2>/dev/null || true
if ! timeout 120 gmake all; then
    echo "${RED}Error: Failed to build GSAssistantFramework${NC}"
    exit 1
fi

# Install framework for proper linking
echo "${YELLOW}Installing framework...${NC}"
if ! sudo -A gmake install; then
    echo "${RED}Error: Failed to install GSAssistantFramework${NC}"
    exit 1
fi
cd ../DebianRuntimeInstaller

# Build the installer
echo "${YELLOW}Building Debian Runtime Installer...${NC}"
if ! timeout 120 gmake all; then
    echo "${RED}Error: Failed to build Debian Runtime Installer${NC}"
    exit 1
fi

echo "${GREEN}Build completed successfully!${NC}"
echo ""
echo "To run the installer:"
echo "  ./obj/DebianRuntimeInstaller"
echo ""
echo "To install:"
echo "  sudo gmake install"
echo ""
