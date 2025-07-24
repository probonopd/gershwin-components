include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = GlobalShortcuts
GlobalShortcuts_OBJC_FILES = GlobalShortcutsPane.m GlobalShortcutsController.m
GlobalShortcuts_RESOURCE_FILES = GlobalShortcuts.png GlobalShortcutsInfo.plist
GlobalShortcuts_BUNDLE_LIBS = -lPreferencePanes
GlobalShortcuts_PRINCIPAL_CLASS = GlobalShortcutsPane
GlobalShortcuts_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# gmake install will install the bundle in /System/Library/Bundles/GlobalShortcuts.prefPane
# gmake uninstall will remove the bundle from /System/Library/Bundles/GlobalShortcuts.prefPane
