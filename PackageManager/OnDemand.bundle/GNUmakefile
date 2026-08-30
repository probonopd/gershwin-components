include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = OnDemand
BUNDLE_EXTENSION = .bundle

OnDemand_OBJC_FILES = OnDemand.m
OnDemand_HEADER_FILES = OnDemand.h

OnDemand_PRINCIPAL_CLASS = OnDemand

OnDemand_LIBS = -lgnustep-gui -lgnustep-base -lobjc
ADDITIONAL_LDFLAGS = -L/System/Library/Frameworks/PackageManager.framework/Versions/1 -lPackageManager
ADDITIONAL_LDFLAGS += -Wl,-rpath,/System/Library/Frameworks/PackageManager.framework/Versions/1

ADDITIONAL_OBJCFLAGS = -Wall -Wextra -fobjc-arc -F/System/Library/Frameworks

after-install::
	@echo "OnDemand.bundle installed to /System/Library/Bundles/"

include $(GNUSTEP_MAKEFILES)/bundle.make
