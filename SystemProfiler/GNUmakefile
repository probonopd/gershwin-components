# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = SystemProfiler
VERSION = 1.0

SystemProfiler_OBJC_FILES = \
	main.m \
	SystemInfo.m \
	SystemProfilerController.m

SystemProfiler_RESOURCE_FILES = SystemProfiler.png

SystemProfiler_HEADERS = \
	AppearanceMetrics.h \
	SystemInfo.h \
	SystemProfilerController.h

SystemProfiler_INFO_PLIST = SystemProfilerInfo.plist

SystemProfiler_OBJCFLAGS = -Wall -O2 -Wno-protocol
SystemProfiler_LDFLAGS = -lgnustep-base -lgnustep-gui -ldispatch -Wl,-rpath,/System/Library/Libraries

# Enable ARC for implementation files in this target
SystemInfo.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
SystemProfilerController.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
main.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions

ADDITIONAL_OBJCFLAGS += -Wno-import

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)

