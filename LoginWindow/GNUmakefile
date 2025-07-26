# GNUmakefile for LoginWindow GNUstep Application

include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = LoginWindow
VERSION = 1.0

LoginWindow_OBJC_FILES = \
    LoginWindow_main.m \
    LoginWindow.m \
    LoginWindowPAM.m

LoginWindow_RESOURCE_FILES = \
    Info.plist

LoginWindow_PRINCIPAL_CLASS = LoginWindow

# Additional libraries
LoginWindow_LDFLAGS += -lpam -lutil

# Installation directories
GNUSTEP_APPS_DIR = /System/Applications

include $(GNUSTEP_MAKEFILES)/application.make

# Install target
install:: all
	@echo "Installing LoginWindow to $(GNUSTEP_APPS_DIR)..."
	mkdir -p $(GNUSTEP_APPS_DIR)
	@if [ -e "$(GNUSTEP_APPS_DIR)/$(APP_NAME).app" ]; then \
		echo "Moving existing LoginWindow.app to temporary location..."; \
		mv "$(GNUSTEP_APPS_DIR)/$(APP_NAME).app" "/tmp/$(APP_NAME).app.backup.$$$$" || true; \
	fi
	cp -r $(APP_NAME).app $(GNUSTEP_APPS_DIR)/
	chmod +x $(GNUSTEP_APPS_DIR)/$(APP_NAME).app/$(APP_NAME)
	@echo "Installation complete."
	@echo "LoginWindow.app installed to $(GNUSTEP_APPS_DIR)"
	@if [ -e "/tmp/$(APP_NAME).app.backup.$$$$" ]; then \
		echo "Old LoginWindow.app backup available at /tmp/$(APP_NAME).app.backup.$$$$"; \
	fi

# Uninstall target
uninstall::
	@echo "Removing LoginWindow from $(GNUSTEP_APPS_DIR)..."
	rm -rf $(GNUSTEP_APPS_DIR)/$(APP_NAME).app
	@echo "Uninstallation complete."

.PHONY: install uninstall
