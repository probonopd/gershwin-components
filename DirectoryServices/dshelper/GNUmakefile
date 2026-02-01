include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = dshelper

dshelper_OBJC_FILES = \
	main.m \
	dshelper.m

dshelper_HEADER_FILES = \
	dshelper.h

dshelper_OBJCFLAGS = -fobjc-arc
dshelper_LDFLAGS = -lcrypt -ldispatch -lBlocksRuntime

# Install to /System/Library/Tools
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

include $(GNUSTEP_MAKEFILES)/tool.make
