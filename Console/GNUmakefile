# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = Console
VERSION = 1.0

Console_OBJC_FILES = \
	main.m \
	LogEntry.m \
	LogQuery.m \
	LogSource.m \
	ConsoleController.m

Console_HEADERS = \
	LogEntry.h \
	LogQuery.h \
	LogSource.h \
	ConsoleController.h

Console_RESOURCE_FILES = \
	Resources/Console.gorm \
	Resources/Console.png

Console_MAIN_MODEL_FILE = Console.gorm

Console_APPLICATION_ICON = Console.png

Console_OBJCFLAGS = -Wall -O2
Console_LDFLAGS = -lgnustep-base -lgnustep-gui -Wl,--disable-new-dtags -Wl,-rpath,/System/Library/Libraries -Wl,-rpath,/Local/Library/Libraries

ADDITIONAL_OBJCFLAGS += -Wno-import

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)

