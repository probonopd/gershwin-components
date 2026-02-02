include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM
GNUSTEP_APPS = $(GNUSTEP_UTILITIES)

APP_NAME = Screenshot
PACKAGE_NAME = Screenshot
Screenshot_PRINCIPAL_CLASS = NSApplication
Screenshot_APPLICATION_ICON = Screenshot.png

#
# Resource files
#
Screenshot_RESOURCE_FILES = \
	Screenshot.png \
	Info.plist

Screenshot_LOCALIZED_RESOURCE_FILES = \
	Localizable.strings

Screenshot_LANGUAGES = English

#
# Source
#
Screenshot_HEADER_FILES = \
	ScreenshotController.h \
	ScreenshotCapture.h

Screenshot_OBJC_FILES = \
	ScreenshotController.m \
	ScreenshotCapture.m

Screenshot_C_FILES = \
	x11_capture.c

Screenshot_OBJC_FILES += Screenshot_main.m

# Link with required libraries
Screenshot_GUI_LIBS += -lX11

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/application.make

-include GNUmakefile.postamble