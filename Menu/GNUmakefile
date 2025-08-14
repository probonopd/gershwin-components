include $(GNUSTEP_MAKEFILES)/common.make

PACKAGE_NAME = Menu
VERSION = 1.0
APP_NAME = Menu

# App info
Menu_APPLICATION_ICON = Menu.png
Menu_PRINCIPAL_CLASS = NSApplication

# Source files
Menu_OBJC_FILES = \
	main.m \
	MenuApplication.m \
	MenuController.m \
	MenuBarView.m \
	AppMenuWidget.m \
	DBusMenuImporter.m \
	DBusMenuParser.m \
	DBusConnection.m \
	MenuUtils.m

# Header files
Menu_HEADER_FILES = \
	MenuApplication.h \
	MenuController.h \
	MenuBarView.h \
	AppMenuWidget.h \
	DBusMenuImporter.h \
	DBusMenuParser.h \
	DBusConnection.h \
	MenuUtils.h

# Resources
Menu_RESOURCE_FILES = \
	Menu.png \
	Info.plist

# Libraries and frameworks
Menu_TOOL_LIBS += -ldbus-1 -lX11
Menu_GUI_LIBS += -lgnustep-gui -lgnustep-base
Menu_LDFLAGS += -Wl,--export-dynamic -L/usr/local/lib

# Compiler flags
ADDITIONAL_OBJCFLAGS = -Wall -Wextra -Werror -O2
ADDITIONAL_CPPFLAGS = -I/usr/local/include/dbus-1.0 -I/usr/local/lib/dbus-1.0/include

# Install path
Menu_INSTALLATION_DIR = $(GNUSTEP_SYSTEM_APPS)

include $(GNUSTEP_MAKEFILES)/application.make

# Post install
after-install::
	$(ECHO_NOTHING)if [ ! -d $(GNUSTEP_SYSTEM_APPS)/Menu.app/Resources ]; then \
		$(MKDIRS) $(GNUSTEP_SYSTEM_APPS)/Menu.app/Resources; \
	fi$(END_ECHO)
	$(ECHO_NOTHING)$(INSTALL_DATA) Menu.png $(GNUSTEP_SYSTEM_APPS)/Menu.app/Resources/$(END_ECHO)
