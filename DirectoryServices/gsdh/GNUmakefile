include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = gsdh

gsdh_OBJC_FILES = \
	main.m \
	gsdh.m

gsdh_HEADER_FILES = \
	gsdh.h

gsdh_OBJCFLAGS = -fobjc-arc
gsdh_LDFLAGS = -lcrypt -ldispatch -lBlocksRuntime

# Install to /System/Library/Tools
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

include $(GNUSTEP_MAKEFILES)/tool.make
