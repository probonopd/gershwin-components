# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = Processes
VERSION = 1.0

Processes_OBJC_FILES = \
	main.m \
	ProcessInfo.m \
	ProcessesController.m

Processes_HEADERS = \
	ProcessInfo.h \
	ProcessesController.h

Processes_RESOURCE_FILES = Resources/Processes.png

Processes_MAIN_MODEL_FILE =

Processes_INFO_PLIST = ProcessesInfo.plist

Processes_APPLICATION_ICON = Processes.icns

Processes_OBJCFLAGS = -Wall -O2
Processes_LDFLAGS = -lgnustep-base -lgnustep-gui -ldispatch -Wl,-rpath,/System/Library/Libraries

# Enable ARC for implementation files in this target
ProcessInfo.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
ProcessesController.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
main.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions

ADDITIONAL_OBJCFLAGS += -Wno-import

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)
