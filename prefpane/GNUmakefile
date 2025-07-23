include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = BootEnvironments
BootEnvironments_OBJC_FILES = BootEnvironmentPane.m BootConfigController.m MainView.m
BootEnvironments_BUNDLE_LIBS = -lPreferencePanes
BootEnvironments_PRINCIPAL_CLASS = BootEnvironmentPane
BootEnvironments_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# gmake install will install the bundle in /System/Library/Bundles/BootEnvironments.prefPane
# gmake uninstall will remove the bundle from /System/Library/Bundles/BootEnvironments.prefPane