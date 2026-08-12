include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = NSICNSImageRep
BUNDLE_EXTENSION = .bundle

NSICNSImageRep_OBJC_FILES = NSICNSImageRep.m
NSICNSImageRep_HEADER_FILES = NSICNSImageRep.h

NSICNSImageRep_PRINCIPAL_CLASS = NSICNSImageRep

ADDITIONAL_OBJCFLAGS += -Wall -Wextra -O2 $(shell pkg-config --cflags libicns)
ADDITIONAL_LDFLAGS += $(shell pkg-config --libs libicns)

NSICNSImageRep_RESOURCE_FILES = NSICNSImageRepInfo.plist

include $(GNUSTEP_MAKEFILES)/bundle.make

after-install::
	@echo "Installing NSICNSImageRep bundle to /System/Library/Bundles/"
		mkdir -p /System/Library/Bundles
		cp -R NSICNSImageRep.bundle /System/Library/Bundles/

