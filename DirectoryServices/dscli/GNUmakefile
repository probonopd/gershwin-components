include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = dscli

dscli_OBJC_FILES = \
	main.m \
	DSPlatform.m \
	DSPlatformFreeBSD.m \
	DSPlatformLinux.m

dscli_OBJCFLAGS = -fobjc-arc
dscli_LDFLAGS = -Wl,-rpath,$(GNUSTEP_SYSTEM_LIBRARIES)
# crypt(3) is in a separate libcrypt on Linux and FreeBSD, but is part of libc
# on OpenBSD (there is no libcrypt to link against).
ifneq ($(findstring openbsd,$(GNUSTEP_HOST_OS)),openbsd)
dscli_LDFLAGS += -lcrypt
endif

# Install to /System/Library/Tools
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

include $(GNUSTEP_MAKEFILES)/tool.make
