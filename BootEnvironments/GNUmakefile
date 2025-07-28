include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = BootEnvironments
BootEnvironments_OBJC_FILES = BootEnvironmentPane.m BootConfigController.m MainView.m
BootEnvironments_RESOURCE_FILES = BootEnvironments.png BootEnvironmentsInfo.plist
BootEnvironments_BUNDLE_LIBS = -lPreferencePanes
BootEnvironments_PRINCIPAL_CLASS = BootEnvironmentPane
PREF_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

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
