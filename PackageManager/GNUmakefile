include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# PackageManager framework - unified package installation/removal API across
# Debian/Arch/FreeBSD/OpenBSD, plus the cross-distro header database that
# maps a #include name to the distro package providing it.
FRAMEWORK_NAME = PackageManager
VERSION = 1.0

PackageManager_OBJC_FILES = \
  GWSystemCommandExecutor.m \
  GWOSDetector.m \
  GWPackageInstallSpec.m \
  GWDebBackend.m \
  GWArchBackend.m \
  GWFreeBSDBackend.m \
  GWOpenBSDBackend.m \
  GWHeaderDatabase.m \
  GWPackageManager.m

PackageManager_HEADER_FILES = \
  GWSystemCommandExecutor.h \
  GWOSDetector.h \
  GWPackageInstallSpec.h \
  GWPackageManagerBackend.h \
  GWDebBackend.h \
  GWArchBackend.h \
  GWFreeBSDBackend.h \
  GWOpenBSDBackend.h \
  GWHeaderDatabase.h \
  GWPackageManager.h

PackageManager_HEADER_FILES_INSTALL_DIR = PackageManager

# The cross-distro header database ships inside the framework so every
# consumer (Build.app, OnDemand.app, ...) resolves headers without extra
# setup.  A future version will download it on demand instead.
PackageManager_RESOURCE_FILES = \
  Resources/headers.db

# All PackageManager code uses ARC
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions
ADDITIONAL_OBJCFLAGS += -Wall -Wextra
ADDITIONAL_OBJCFLAGS += -Wno-nullability-completeness -Wno-unused-parameter

# Only needs Foundation and libdispatch for dispatch_once
PackageManager_FRAMEWORKS_DEPEND_UPON = Foundation
ADDITIONAL_LDFLAGS += -ldispatch

# sqlite3 for the header database (pkg-config is the reliable way to get the
# right flags on every platform; fall back to the plain library name).
SQLITE_LIBS := $(shell pkg-config --libs sqlite3 2>/dev/null || echo -lsqlite3)
ADDITIONAL_LDFLAGS += $(SQLITE_LIBS)

FRAMEWORK_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Frameworks

include $(GNUSTEP_MAKEFILES)/framework.make

# A framework bundle contains symlinks (Versions/Current, Resources, Headers).
# Copying over an existing install makes cp descend into those symlinked
# directories: GNU cp replaces the link, but BSD cp refuses with
#   "cannot overwrite directory ... with non-directory"
# which broke reinstalls on OpenBSD. Remove the old bundle first so the copy
# always lands on a clean target. (Same pattern as GSAssistantFramework.)
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(FRAMEWORK_NAME).framework
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(FRAMEWORK_NAME) to $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(FRAMEWORK_INSTALL_DIR); \
		rm -rf $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
		cp -R $(FRAMEWORK_NAME).framework $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)/; \
	else \
		echo "Installing $(FRAMEWORK_NAME) to $(FRAMEWORK_INSTALL_DIR)"; \
		mkdir -p $(FRAMEWORK_INSTALL_DIR); \
		rm -rf $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
		cp -R $(FRAMEWORK_NAME).framework $(FRAMEWORK_INSTALL_DIR)/; \
	fi

uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(FRAMEWORK_NAME) from $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)"; \
		rm -rf $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
	else \
		echo "Uninstalling $(FRAMEWORK_NAME) from $(FRAMEWORK_INSTALL_DIR)"; \
		rm -rf $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
	fi

# Build OnDemand.app (recursive make - not a GNUstep subproject)
ONDEMAND_DIR = OnDemand
.PHONY: ondemand
ondemand:
	$(MAKE) -C $(ONDEMAND_DIR) all

# Build Placeholder wrapper bundles (standalone makefile)
PLACEHOLDERS_DIR = Placeholders
.PHONY: placeholders
placeholders: ondemand
	$(MAKE) -C $(PLACEHOLDERS_DIR) all

# Build everything in order: framework first, then the apps that use it.
# OnDemand links the framework from /System and is therefore only built during
# install (after the framework has been placed there), not by plain 'gmake'.
all::
	@echo "PackageManager framework built; OnDemand.app is built during 'gmake install'."

# Test suite (separate tool that links the framework)
.PHONY: test
test: all
	$(MAKE) -C Tests test

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
	$(MAKE) -C Tests clean 2>/dev/null || true
