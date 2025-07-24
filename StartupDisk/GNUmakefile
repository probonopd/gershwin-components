include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = StartupDisk
StartupDisk_OBJC_FILES = StartupDiskPane.m StartupDiskController.m
StartupDisk_RESOURCE_FILES = StartupDisk.png StartupDiskInfo.plist
StartupDisk_BUNDLE_LIBS = -lPreferencePanes
StartupDisk_PRINCIPAL_CLASS = StartupDiskPane
StartupDisk_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# gmake install will install the bundle in /System/Library/Bundles/StartupDisk.prefPane
# gmake uninstall will remove the bundle from /System/Library/Bundles/StartupDisk.prefPane
