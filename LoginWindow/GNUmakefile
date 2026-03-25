# GNUmakefile for LoginWindow GNUstep Application

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_APPS = $(GNUSTEP_SYSTEM_SERVICES)

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
# Ensure we search /usr/local/lib (FreeBSD ports) for libXau
LoginWindow_LDFLAGS += -L/usr/local/lib -lpam -lutil -lX11 -lXau

# Installation directories
INSTALL_APPS_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/CoreServices/Applications

include $(GNUSTEP_MAKEFILES)/application.make

# Install target
install:: all
	@echo "Installing LoginWindow.app..."
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing to $(DESTDIR)$(INSTALL_APPS_DIR)"; \
		/System/Library/Makefiles/mkinstalldirs "$(DESTDIR)$(INSTALL_APPS_DIR)"; \
		(cd .; tar chfX - /System/Library/Makefiles/tar-exclude-list $(APP_NAME).app) | (cd "$(DESTDIR)$(INSTALL_APPS_DIR)"; tar xf -); \
	else \
		echo "Installing to $(INSTALL_APPS_DIR)"; \
		/System/Library/Makefiles/mkinstalldirs "$(INSTALL_APPS_DIR)"; \
		(cd .; tar chfX - /System/Library/Makefiles/tar-exclude-list $(APP_NAME).app) | sh -c 'cd "$(INSTALL_APPS_DIR)" && tar xf -'; \
	fi
	@echo "Installing service script..."
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing to $(DESTDIR)/usr/local/etc/rc.d/loginwindow (staged install)"; \
		mkdir -p $(DESTDIR)/usr/local/etc/rc.d; \
		install -m 555 loginwindow $(DESTDIR)/usr/local/etc/rc.d/loginwindow; \
	elif [ -d "/usr/local/etc/rc.d" ]; then \
		echo "Installing to /usr/local/etc/rc.d/loginwindow (FreeBSD rc.d)"; \
		install -m 555 loginwindow /usr/local/etc/rc.d/loginwindow; \
	elif [ -d /run/systemd/system ]; then \
		echo "Installing loginwindow.service (systemd)"; \
		install -m 644 loginwindow.service /etc/systemd/system/loginwindow.service; \
	elif [ -d /etc/init.d ]; then \
		echo "Installing loginwindow init script (sysvinit)"; \
		install -m 755 loginwindow.init /etc/init.d/loginwindow; \
	else \
		echo "No supported init system detected, skipping service install."; \
	fi
	@echo "Note: PAM configuration will be auto-generated to enable X11 authorization"
	@echo "Installation complete."

# Uninstall target
uninstall::
	@echo "Removing LoginWindow from $(INSTALL_APPS_DIR)..."
	rm -rf $(INSTALL_APPS_DIR)/$(APP_NAME).app
	@echo "Uninstallation complete."

# Override built-in install targets to do nothing
$(APP_NAME).install.application.variables::
	@true

shared-instance-application-install::
	@true

internal-application-install::
	@true

.PHONY: install uninstall
