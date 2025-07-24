include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = Display
Display_OBJC_FILES = DisplayPane.m DisplayController.m DisplayView.m
Display_RESOURCE_FILES = Display.png DisplayInfo.plist
Display_BUNDLE_LIBS = -lPreferencePanes
Display_PRINCIPAL_CLASS = DisplayPane
Display_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# gmake install will install the bundle in /System/Library/Bundles/Display.prefPane
# gmake uninstall will remove the bundle from /System/Library/Bundles/Display.prefPane
