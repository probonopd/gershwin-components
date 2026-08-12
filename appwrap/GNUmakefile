include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TOOL_NAME = appwrap mkcombinedicon

# Source files for appwrap
appwrap_OBJC_FILES = \
	appwrap.m \
	GWBundleCreator.m \
	GWDocumentIcon.m \
	DesktopFileParser.m \
	GWUtils.m

# Source files for mkcombinedicon
mkcombinedicon_OBJC_FILES = \
	mkcombinedicon.m \
	GWDocumentIcon.m \
	GWUtils.m

# Install explicitly into the GNUstep Tools directory
appwrap_INSTALL_DIR = $(GNUSTEP_TOOLS)
mkcombinedicon_INSTALL_DIR = $(GNUSTEP_TOOLS)

# Compiler and flags per project guidelines
# Prefer clang19; fall back to clang or system cc if unavailable
CC ?= $(shell command -v clang19 2>/dev/null || command -v clang 2>/dev/null || echo cc)
ADDITIONAL_OBJCFLAGS += -Wall -Wextra -Werror -O2

# Link GNUstep Foundation (and GUI if needed)
ADDITIONAL_LDFLAGS += -lgnustep-base -lgnustep-gui

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/tool.make

-include GNUmakefile.postamble

