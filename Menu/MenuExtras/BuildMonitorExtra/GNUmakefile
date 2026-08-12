include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = BuildMonitor
BUNDLE_EXTENSION = .gsmenuextra

BuildMonitor_PRINCIPAL_CLASS = BuildMonitorExtra
BuildMonitor_OBJC_FILES = BuildMonitorExtra.m
BuildMonitor_RESOURCE_FILES = Info.plist

ADDITIONAL_OBJCFLAGS += -I../.. -fobjc-arc

include $(GNUSTEP_MAKEFILES)/bundle.make

