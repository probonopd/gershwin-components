include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# Unit tests for GWBuildPreflight's header resolution.
TEST_TOOL_NAME = t_PreflightHeaders

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_OBJCFLAGS += -Wall -Wextra -Wno-nullability-completeness

t_PreflightHeaders_OBJC_FILES = t_PreflightHeaders.m

# The preflight pulls in AppKit (NSAlert consent prompt) and PackageManager.
t_PreflightHeaders_TOOL_LIBS += -lgnustep-gui
ADDITIONAL_OBJCFLAGS += -I..
ADDITIONAL_LDFLAGS += -ldispatch
ADDITIONAL_LDFLAGS += -L/System/Library/Frameworks/PackageManager.framework/Versions/1 -lPackageManager
ADDITIONAL_LDFLAGS += -Wl,-rpath,/System/Library/Frameworks/PackageManager.framework/Versions/1

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/test-tool.make
