include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = WLAN
BUNDLE_EXTENSION = .gsmenuextra

WLAN_PRINCIPAL_CLASS = WLANExtra
WLAN_OBJC_FILES = WLANExtra.m

WLAN_BUNDLE_LIBS += -lNetworkBackend
ADDITIONAL_OBJCFLAGS += -I../.. -I../../../Network -I../../../Libraries/NetworkBackend -I/System/Library/Headers/NetworkBackend -fobjc-arc

include $(GNUSTEP_MAKEFILES)/bundle.make

