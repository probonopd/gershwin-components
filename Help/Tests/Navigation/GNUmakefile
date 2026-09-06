# Tests for M4 navigation helpers (history, man locator, app scanner).
# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_Navigation_History t_Navigation_ManLocator \
                 t_Navigation_AppScanner

# Testing.h is not ARC-clean, so only the library sources are compiled
# with ARC (per-file flags); the test TUs stay reference-counted.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ARCFLAGS = -fobjc-arc -fobjc-runtime=gnustep-2.0
../../Sources/Core/GSHelpManLocator.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpAppScanner.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpURL.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Navigation/GSHelpHistory.m_FILE_FLAGS = $(ARCFLAGS)
ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework \
                       -I../../Sources/Core -I../../Sources/Navigation

t_Navigation_History_OBJC_FILES = t_Navigation_History.m \
                                  ../../Sources/Navigation/GSHelpHistory.m \
                                  ../../Sources/Core/GSHelpURL.m

t_Navigation_ManLocator_OBJC_FILES = t_Navigation_ManLocator.m \
                                     ../../Sources/Core/GSHelpManLocator.m

t_Navigation_AppScanner_OBJC_FILES = t_Navigation_AppScanner.m \
                                     ../../Sources/Core/GSHelpAppScanner.m

include $(GNUSTEP_MAKEFILES)/test-tool.make
