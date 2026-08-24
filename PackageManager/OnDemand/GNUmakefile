include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = OnDemand
PACKAGE_NAME = OnDemand
OnDemand_PRINCIPAL_CLASS = NSApplication
OnDemand_APPLICATION_ICON =

# Source files.  The PackageManager framework is built first by the parent
# GNUmakefile; we link against it instead of bundling the sources.
OnDemand_OBJC_FILES = \
  main.m \
  OnDemandController.m

# Resource files (plists); the app Info.plist is merged by gnustep-make
OnDemand_RESOURCE_FILES = \
  Resources/Install.plist

# ARC throughout
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions
ADDITIONAL_OBJCFLAGS += -Wall -Wextra
ADDITIONAL_OBJCFLAGS += -Wno-nullability-completeness -Wno-unused-parameter

# Link against the PackageManager framework, which is installed system-wide to
# /System/Library/Frameworks by 'gmake install' in the parent directory.  The
# app does not embed the framework; it resolves it via the system install.
ADDITIONAL_OBJCFLAGS += -I/System/Library/Headers
ADDITIONAL_LDFLAGS += -L/System/Library/Frameworks/PackageManager.framework/Versions/1 -lPackageManager
ADDITIONAL_LDFLAGS += -Wl,-rpath,/System/Library/Frameworks/PackageManager.framework/Versions/1

# Link with AppKit, Foundation, and libdispatch
OnDemand_FRAMEWORKS_DEPEND_UPON = AppKit Foundation
ADDITIONAL_LDFLAGS += -ldispatch

include $(GNUSTEP_MAKEFILES)/application.make

# Manual copy of resource files into built app
$(APP_NAME).app/Resources/Install.plist: Resources/Install.plist
	mkdir -p $(@D) && cp $< $@

all:: $(APP_NAME).app/Resources/Install.plist

# Do not invoke sudo unconditionally. Image builds and CI run as root, and a
# stock FreeBSD/OpenBSD install has no sudo at all, so this failed with
# "sudo: No such file or directory" (exit 127). Use it only when we are not
# root and it is actually available.
SUDO := $(shell if [ "$$(id -u)" = "0" ]; then echo ""; \
	elif command -v sudo >/dev/null 2>&1; then echo "sudo"; \
	else echo ""; fi)

system-install: $(APP_NAME).app
	$(SUDO) mkdir -p /System/Applications/Utilities
	$(SUDO) rm -rf /System/Applications/Utilities/$(APP_NAME).app
	$(SUDO) cp -R $(APP_NAME).app /System/Applications/Utilities/
	$(SUDO) chmod -R a+rX /System/Applications/Utilities/$(APP_NAME).app
	$(SUDO) make_services
	@echo "Installed $(APP_NAME).app to /System/Applications/Utilities/; services database updated"
