# make_appimage - command line tool for building AppImages from GNUstep apps.
# Shell script, installed directly to GNUSTEP_SYSTEM_TOOLS.

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

include $(GNUSTEP_MAKEFILES)/common.make

.PHONY: all build install clean distclean

TOOLS_DIR = $(GNUSTEP_SYSTEM_TOOLS)

all build:
	@true

install:
	@echo "Installing make_appimage to $(TOOLS_DIR)"
	@mkdir -p $(TOOLS_DIR)
	@cp make_appimage $(TOOLS_DIR)/make_appimage
	@chmod 755 $(TOOLS_DIR)/make_appimage
	@echo "Installed make_appimage"

clean distclean:
	@echo "Nothing to clean"
