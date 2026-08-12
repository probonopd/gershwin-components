include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

SUBPROJECTS = efivar

# Compiler flags for production builds
Keyboard_OBJCFLAGS += -Wall -Wextra -Werror -O2

BUNDLE_NAME = Keyboard
Keyboard_OBJC_FILES = KeyboardPane.m KeyboardController.m
Keyboard_RESOURCE_FILES = Keyboard.png KeyboardInfo.plist
Keyboard_BUNDLE_LIBS = -lPreferencePanes
Keyboard_PRINCIPAL_CLASS = KeyboardPane
PREF_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# Custom install target mirroring GlobalShortcuts behavior
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

