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
LoginWindow_LDFLAGS += -lpam -lutil -lX11

# Installation directories
GNUSTEP_APPS_DIR = /System/Applications

include $(GNUSTEP_MAKEFILES)/application.make

# Install target
install:: all
	@echo "Installing LoginWindow.app..."
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing to $(DESTDIR)$(GNUSTEP_APPS_DIR)/$(APP_NAME).app (staged install)"; \
		mkdir -p $(DESTDIR)$(GNUSTEP_APPS_DIR); \
		cp -R $(APP_NAME).app $(DESTDIR)$(GNUSTEP_APPS_DIR)/$(APP_NAME).app; \
	else \
		echo "Installing to $(GNUSTEP_APPS_DIR)/$(APP_NAME).app (system install)"; \
		sudo -A mkdir -p $(GNUSTEP_APPS_DIR); \
		sudo -A cp -R $(APP_NAME).app $(GNUSTEP_APPS_DIR)/$(APP_NAME).app; \
	fi
	@echo "Installing rc.d script..."
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing to $(DESTDIR)/usr/local/etc/rc.d/loginwindow (staged install)"; \
		mkdir -p $(DESTDIR)/usr/local/etc/rc.d; \
		install -m 555 loginwindow $(DESTDIR)/usr/local/etc/rc.d/loginwindow; \
	else \
		echo "Installing to /usr/local/etc/rc.d/loginwindow (system install)"; \
		sudo -A install -m 555 loginwindow /usr/local/etc/rc.d/loginwindow; \
	fi
	@echo "Installation complete."

# Uninstall target
uninstall::
	@echo "Removing LoginWindow from $(GNUSTEP_APPS_DIR)..."
	rm -rf $(GNUSTEP_APPS_DIR)/$(APP_NAME).app
	@echo "Uninstallation complete."

.PHONY: install uninstall
