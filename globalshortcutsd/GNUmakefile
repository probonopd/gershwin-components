include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = globalshortcutsd

globalshortcutsd_OBJC_FILES = globalshortcutsd.m

# Link with X11 libraries
globalshortcutsd_LDFLAGS += -lX11

# Include X11 headers
globalshortcutsd_CPPFLAGS += -I/usr/include/X11

# Use clang19 as specified in instructions
CC = clang19
OBJC = clang19

include $(GNUSTEP_MAKEFILES)/tool.make
