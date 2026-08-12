include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TOOL_NAME = PackageManagerTest

PackageManagerTest_OBJC_FILES = \
  GWSystemCommandExecutor.m \
  GWOSDetector.m \
  GWPackageInstallSpec.m \
  GWDebBackend.m \
  GWArchBackend.m \
  GWFreeBSDBackend.m \
  GWOpenBSDBackend.m \
  GWPackageManager.m \
  PackageManagerTest.m

# All PackageManager code uses ARC
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions
ADDITIONAL_OBJCFLAGS += -Wall -Wextra
ADDITIONAL_OBJCFLAGS += -Wno-nullability-completeness -Wno-unused-parameter

# Only needs Foundation and libdispatch for dispatch_once
PackageManagerTest_FRAMEWORKS_DEPEND_UPON = Foundation
ADDITIONAL_LDFLAGS += -ldispatch

include $(GNUSTEP_MAKEFILES)/tool.make

before-install::
	@echo "PackageManager test built successfully"

test: all
	./obj/PackageManagerTest

# Build OnDemand.app (recursive make — not a GNUstep subproject)
ONDEMAND_DIR = OnDemand
.PHONY: ondemand
ondemand:
	$(MAKE) -C $(ONDEMAND_DIR) all

# Build Placeholder wrapper bundles (standalone makefile)
PLACEHOLDERS_DIR = Placeholders
.PHONY: placeholders
placeholders: ondemand
	$(MAKE) -C $(PLACEHOLDERS_DIR) all

# Build everything in order
all:: ondemand placeholders

# System install targets
.PHONY: system-install
system-install: ondemand
	$(MAKE) -C $(ONDEMAND_DIR) system-install
	$(MAKE) -C $(PLACEHOLDERS_DIR) system-install

# Also install OnDemand and Placeholders on plain "gmake install"
after-install:: ondemand placeholders
	$(MAKE) -C $(ONDEMAND_DIR) system-install
	$(MAKE) -C $(PLACEHOLDERS_DIR) system-install

# Forward clean to subdirectories
clean::
	$(MAKE) -C $(ONDEMAND_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(PLACEHOLDERS_DIR) clean 2>/dev/null || true

