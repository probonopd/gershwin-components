include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = Display
Display_OBJC_FILES = DisplayPane.m DisplayController.m DisplayView.m
Display_RESOURCE_FILES = Display.png DisplayInfo.plist
Display_BUNDLE_LIBS = -lPreferencePanes
Display_PRINCIPAL_CLASS = DisplayPane
PREF_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# gmake install will install the bundle in /System/Library/Bundles/Display.prefPane
# gmake uninstall will remove the bundle from /System/Library/Bundles/Display.prefPane

# Custom install target that completely overrides built-in behavior
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
		sudo -A cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(PREF_INSTALL_DIR)/; \
	fi

# Override uninstall target to properly support DESTDIR
uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(BUNDLE_NAME) from $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		rm -rf $(DESTDIR)$(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
	else \
		echo "Uninstalling $(BUNDLE_NAME) from $(PREF_INSTALL_DIR)"; \
		sudo -A rm -rf $(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
	fi

# Override built-in install targets to do nothing
$(BUNDLE_NAME).install.bundle.variables::
	@true

shared-instance-bundle-install::
	@true

internal-bundle-install::
	@true

.PHONY: install uninstall
