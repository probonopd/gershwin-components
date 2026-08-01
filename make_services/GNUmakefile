include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = make_services

# Source files for make_services
make_services_OBJC_FILES = \
	make_services.m \
	AppImageReader.m

# Install explicitly into the GNUstep Tools directory
make_services_INSTALL_DIR = $(GNUSTEP_TOOLS)

# Compiler and flags per project guidelines
# Prefer clang19; fall back to clang or system cc if unavailable
CC ?= $(shell command -v clang19 2>/dev/null || command -v clang 2>/dev/null || echo cc)
ADDITIONAL_OBJCFLAGS += -Wall -Wextra -Wno-unused-parameter -O2

# make_services is a Foundation tool; libsquashfs is used to read the
# *.desktop file out of AppImage applications
ADDITIONAL_LDFLAGS += -lgnustep-base -lsquashfs

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/tool.make

-include GNUmakefile.postamble
