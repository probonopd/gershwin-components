#!/bin/sh
# Script to run the GNUstep application as root

echo "Running Boot Environment Manager as root..."
echo "This is required for creating and deleting boot environments."

sudo -A -E sh -c ". /usr/local/GNUstep/System/Makefiles/GNUstep.sh && openapp ./BootEnvironments.app"
