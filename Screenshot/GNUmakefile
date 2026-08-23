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
	Resources/Screenshot.png \
	Resources/Info.plist

Screenshot_LOCALIZED_RESOURCE_FILES = \
	Localizable.strings

Screenshot_LANGUAGES = English

# Build-time generation of Info files
Resources/Info.plist: Info.plist | Resources
	$(ECHO_NOTHING)if [ -n "$(INSTALL_FILE)" ]; then $(INSTALL_FILE) $< $@; else cp $< $@; fi$(END_ECHO)

Resources/Info-gnustep.plist: Resources/Info.plist
	$(ECHO_NOTHING)if command -v plmerge >/dev/null 2>&1; then \
	  plmerge $< "$(GNUSTEP_PLIST_DEPEND)" > $@; \
	else \
	  cp $< $@; \
	fi$(END_ECHO)

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

# Ensure Info.plist is copied into the built app and Info-gnustep is generated from it
# Make 'all' depend on copying/generation so it happens during normal builds
all:: copy-info

copy-info: $(APP_NAME).app
	$(ECHO_NOTHING)if [ -n "$(INSTALL_FILE)" ]; then $(INSTALL_FILE) Info.plist $(APP_NAME).app/Resources/Info.plist; else cp Info.plist $(APP_NAME).app/Resources/Info.plist; fi$(END_ECHO)
	$(ECHO_NOTHING)if command -v plmerge >/dev/null 2>&1; then \
	  plmerge $(APP_NAME).app/Resources/Info-gnustep.plist Info.plist "$(GNUSTEP_PLIST_DEPEND)"; \
	fi$(END_ECHO)
	# Ensure .desktop file exists (pl2link not available on this system)
	$(ECHO_NOTHING)touch $(APP_NAME).app/Resources/$(APP_NAME).desktop$(END_ECHO)

-include GNUmakefile.postamble