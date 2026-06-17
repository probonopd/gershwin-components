include $(GNUSTEP_MAKEFILES)/common.make

# A standalone AppKit user bundle that vends the UIBridge introspection /
# automation Distributed Objects service. Autoloaded into every GNUstep app
# via the GSAppKitUserBundles default, so it is available under ANY GSTheme
# (including the base theme) rather than living inside the Eau theme.

BUNDLE_NAME = UIBridge
BUNDLE_EXTENSION = .bundle
VERSION = 0.1

UIBridge_PRINCIPAL_CLASS = UIBridgeLoader

UIBridge_OBJC_FILES = \
		UIBridgeLoader.m \
		UIBridgeService.m

# Link the GUI/Foundation stacks: the service walks the live AppKit tree.
UIBridge_BUNDLE_LIBS += -lgnustep-gui -lgnustep-base

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions

# Installed where AppKit looks up GSAppKitUserBundles.
UIBridge_INSTALL_DIR = $(GNUSTEP_LIBRARY)/Bundles

include $(GNUSTEP_MAKEFILES)/bundle.make
