include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# Compiler flags for production builds
# Note: -Wno-deprecated-declarations suppresses warning for cupsGetDevices which is
# deprecated but still the standard way to discover printers
Printers_OBJCFLAGS += -Wall -Wextra -O2 -Wno-deprecated-declarations

BUNDLE_NAME = Printers
Printers_OBJC_FILES = PrintersPane.m PrintersController.m
Printers_RESOURCE_FILES = Printers.png PrintersInfo.plist
Printers_BUNDLE_LIBS = -lPreferencePanes -lcups
Printers_PRINCIPAL_CLASS = PrintersPane
PREF_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

# CUPS include and library paths
Printers_INCLUDE_DIRS += -I/usr/include
Printers_LIB_DIRS += -L/usr/lib -L/usr/lib/x86_64-linux-gnu

include $(GNUSTEP_MAKEFILES)/bundle.make

# Custom install target mirroring other preference panes behavior
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(BUNDLE_NAME)$(BUNDLE_EXTENSION)
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(BUNDLE_NAME) to $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(DESTDIR)$(PREF_INSTALL_DIR)/; \
	else \
		echo "Installing $(BUNDLE_NAME) to $(PREF_INSTALL_DIR)"; \
		mkdir -p $(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(PREF_INSTALL_DIR)/; \
	fi

# Override uninstall target to properly support DESTDIR
uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(BUNDLE_NAME) from $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		rm -rf $(DESTDIR)$(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
	else \
		echo "Uninstalling $(BUNDLE_NAME) from $(PREF_INSTALL_DIR)"; \
		rm -rf $(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
	fi

# Override built-in install targets to do nothing
$(BUNDLE_NAME).install.bundle.variables::
	@true

shared-instance-bundle-install::
	@true

internal-bundle-install::
	@true

.PHONY: install uninstall

