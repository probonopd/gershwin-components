include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# Test suite for the PackageManager framework.  Links against the framework
# built in the parent directory, so the framework must be built first
# (the parent GNUmakefile's "test" target ensures that).
TOOL_NAME = PackageManagerTest

PackageManagerTest_OBJC_FILES = PackageManagerTest.m

# All PackageManager code uses ARC
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions
ADDITIONAL_OBJCFLAGS += -Wall -Wextra
ADDITIONAL_OBJCFLAGS += -Wno-nullability-completeness -Wno-unused-parameter

# Framework headers and library (built locally, not yet installed in /System)
ADDITIONAL_OBJCFLAGS += -I../PackageManager.framework/Versions/1/Headers
ADDITIONAL_LDFLAGS += -L../PackageManager.framework/Versions/1 -lPackageManager
# Make the freshly linked test tool find the framework .so at runtime.
ADDITIONAL_LDFLAGS += -Wl,-rpath,$(abspath ../PackageManager.framework/Versions/1)

# Only needs Foundation and libdispatch for dispatch_once
PackageManagerTest_FRAMEWORKS_DEPEND_UPON = Foundation
ADDITIONAL_LDFLAGS += -ldispatch

include $(GNUSTEP_MAKEFILES)/tool.make

before-install::
	@echo "PackageManager test built successfully"

# Run against the freshly built local framework.  The GNUstep environment puts
# /System/Library/Libraries on LD_LIBRARY_PATH, which the loader consults
# before the tool's RUNPATH; without an explicit LD_LIBRARY_PATH prefix the
# test would exercise a stale installed copy of the framework.
test: all
	LD_LIBRARY_PATH=$(abspath ../PackageManager.framework/Versions/1)$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH} ./obj/PackageManagerTest