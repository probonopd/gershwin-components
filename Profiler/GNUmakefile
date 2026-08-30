# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = Profiler
VERSION = 1.0

Profiler_OBJC_FILES = \
	Sources/main.m \
	Sources/AppDelegate.m \
	Sources/ProfilerWindowController.m \
	Sources/ProcessInfo.m \
	Sources/ProcessMonitor.m \
	Sources/GraphView.m \
	Sources/HotspotTableController.m \
	Sources/ProfilerController.m

Profiler_HEADERS = \
	Sources/AppDelegate.h \
	Sources/ProfilerWindowController.h \
	Sources/ProcessInfo.h \
	Sources/ProcessMonitor.h \
	Sources/GraphView.h \
	Sources/HotspotTableController.h \
	Sources/ProfilerController.h

Profiler_RESOURCE_FILES = Resources/Dependencies.plist

Profiler_MAIN_MODEL_FILE =

Profiler_OBJCFLAGS = -Wall -O2
Profiler_LDFLAGS = -lgnustep-base -lgnustep-gui -ldispatch -Wl,-rpath,/System/Library/Libraries

AppDelegate.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
ProfilerWindowController.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
ProcessInfo.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
ProcessMonitor.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
GraphView.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
HotspotTableController.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
ProfilerController.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
main.m_FILE_FLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions

ADDITIONAL_OBJCFLAGS += -Wno-import

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)
