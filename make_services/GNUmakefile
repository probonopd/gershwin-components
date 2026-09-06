include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TOOL_NAME = make_services

# Source files for make_services
make_services_OBJC_FILES = \
	make_services.m \
	AppImageReader.m \
	../appwrap/GWDocumentIcon.m \
	../appwrap/GWUtils.m

# Install into the system tools directory so this AppImage-aware make_services
# overwrites the one shipped with libs-gui.
make_services_INSTALL_DIR = /System/Library/Tools

# Compiler and flags per project guidelines
# Prefer clang19; fall back to clang or system cc if unavailable
CC ?= $(shell command -v clang19 2>/dev/null || command -v clang 2>/dev/null || echo cc)
ADDITIONAL_OBJCFLAGS += -Wall -Wextra -Wno-unused-parameter -O2

# make_services is a Foundation tool; AppKit (via -lgnustep-gui) is needed to
# composite the document icons for AppImage file types.
ADDITIONAL_LDFLAGS += -lgnustep-base -lgnustep-gui

# libsquashfs (squashfs-tools-ng) provides the sqfs/ headers used to read
# *.desktop files out of AppImage applications.  It is not packaged on every
# supported OS (e.g. Arch and OpenBSD), so it is detected at build time: when
# absent make_services still builds, just without AppImage support.
SQUASHFS_AVAILABLE := $(shell echo '#include <sqfs/predef.h>' | $(CC) -fsyntax-only -x c - 2>/dev/null && echo YES)
ifeq ($(SQUASHFS_AVAILABLE),YES)
ADDITIONAL_OBJCFLAGS += -DHAVE_LIBSQUASHFS=1
ADDITIONAL_LDFLAGS += -lsquashfs
else
$(warning libsquashfs (squashfs-tools-ng) not found: make_services will be built WITHOUT AppImage application support)
endif

# GWDocumentIcon.m/GWUtils.m live in ../appwrap
ADDITIONAL_CPPFLAGS += -I../appwrap

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/tool.make

-include GNUmakefile.postamble
