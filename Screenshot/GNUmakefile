include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = Screenshot
PACKAGE_NAME = Screenshot
Screenshot_PRINCIPAL_CLASS = NSApplication
Screenshot_APPLICATION_ICON = Screenshot.png

#
# Resource files
#
Screenshot_RESOURCE_FILES = \
	Resources/Screenshot.png

Screenshot_LOCALIZED_RESOURCE_FILES = \
	Localizable.strings

Screenshot_LANGUAGES = English


#
# Source
#
Screenshot_HEADER_FILES = \
	ScreenshotController.h \
	ScreenshotCapture.h \
	shadow_mask.h

Screenshot_OBJC_FILES = \
	ScreenshotController.m \
	ScreenshotCapture.m

Screenshot_C_FILES = \
	x11_capture.c \
	shadow_mask.c

Screenshot_OBJC_FILES += Screenshot_main.m

# Link with required libraries
Screenshot_GUI_LIBS += -lX11 -lXext

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)


-include GNUmakefile.postamble