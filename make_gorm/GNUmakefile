# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause

include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = make_gorm
VERSION = 1.0

make_gorm_OBJC_FILES = \
	make_gorm.m \
	MGTypes.m \
	MGArchiverReader.m \
	MGArchiverWriter.m \
	MGTextWriter.m \
	MGTextReader.m \
	MGCompiler.m

make_gorm_OBJCFLAGS = -Wall -O2

# -lgnustep-gui needed for class table reconstruction (NSClassFromString)
# -DRECORDING_CODER also needs it for NSApplication
make_gorm_LDFLAGS = -lgnustep-base -lgnustep-gui \
	-Wl,--disable-new-dtags \
	-Wl,-rpath,/System/Library/Libraries \
	-Wl,-rpath,/Local/Library/Libraries

ADDITIONAL_OBJCFLAGS += -Wno-import

# Install to /System/Library/Tools
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# Man page installation
MANPAGE = make_gorm.1
INSTALL_MAN_DIR = $(GNUSTEP_DOC_MAN)/man1

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/tool.make

-include GNUmakefile.postamble

# Install man page
after-install::
	$(ECHO_NOTHING)if [ ! -d "$(INSTALL_MAN_DIR)" ]; then \
	  $(MKINSTALLDIRS) "$(INSTALL_MAN_DIR)"; \
	fi; \
	$(INSTALL_DATA) $(MANPAGE) "$(INSTALL_MAN_DIR)/$(MANPAGE)"$(END_ECHO)
	@echo "Installed $(MANPAGE) to $(INSTALL_MAN_DIR)"

# Uninstall man page
after-uninstall::
	$(ECHO_NOTHING)rm -f "$(INSTALL_MAN_DIR)/$(MANPAGE)"$(END_ECHO)
	@echo "Removed $(INSTALL_MAN_DIR)/$(MANPAGE)"
