# GNUmakefile for LoginWindow GNUstep Application

include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM
GNUSTEP_APPS = $(GNUSTEP_CORE_SERVICES_APPS)

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

include $(GNUSTEP_MAKEFILES)/application.make

after-install::
	@echo "Installing rc.d script..."
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing to $(DESTDIR)/usr/local/etc/rc.d/loginwindow (staged install)"; \
		mkdir -p $(DESTDIR)/usr/local/etc/rc.d; \
		install -m 555 loginwindow $(DESTDIR)/usr/local/etc/rc.d/loginwindow; \
	else \
		if [ -d "/usr/local/etc/rc.d" ]; then \
			echo "Installing to /usr/local/etc/rc.d/loginwindow (system install)"; \
			install -m 555 loginwindow /usr/local/etc/rc.d/loginwindow; \
		else \
			echo "/usr/local/etc/rc.d does not exist, skipping rc.d script install."; \
		fi; \
	fi
	@echo "Note: PAM configuration will be auto-generated to enable X11 authorization"
	@echo "Installation complete."
