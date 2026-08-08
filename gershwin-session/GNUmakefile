include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TOOL_NAME = gershwin-session
gershwin-session_OBJC_FILES = gershwin-session.m
gershwin-session_TOOL_LIBS = -lgnustep-base -lobjc

ADDITIONAL_OBJCFLAGS = -Wall -Wextra -fobjc-arc

# Install into /System/Library/Tools so every user session can find it on
# the standard tool PATH.
TOOL_INSTALL_DIR = $(GNUSTEP_SYSTEM_TOOLS)

include $(GNUSTEP_MAKEFILES)/tool.make