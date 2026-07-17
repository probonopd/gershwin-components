include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = OnDemand
PACKAGE_NAME = OnDemand
OnDemand_PRINCIPAL_CLASS = NSApplication
OnDemand_APPLICATION_ICON =

# Bundle PackageManager sources into a local directory at build time
# (GNUstep make doesn't support source files outside the project dir)
PACKAGE_MANAGER_SRC = ..
BUNDLED_PM_SRC = _pmsrc

# Copy PackageManager .m files into local _pmsrc/ at make parse time
# (clean removes the dir to force fresh copy on next build)
_BUNDLED := $(shell mkdir -p $(BUNDLED_PM_SRC) && cp $(PACKAGE_MANAGER_SRC)/GW*.m $(BUNDLED_PM_SRC)/ 2>/dev/null)

# Source files
OnDemand_OBJC_FILES = \
  main.m \
  OnDemandController.m \
  $(BUNDLED_PM_SRC)/GWSystemCommandExecutor.m \
  $(BUNDLED_PM_SRC)/GWOSDetector.m \
  $(BUNDLED_PM_SRC)/GWPackageInstallSpec.m \
  $(BUNDLED_PM_SRC)/GWDebBackend.m \
  $(BUNDLED_PM_SRC)/GWArchBackend.m \
  $(BUNDLED_PM_SRC)/GWFreeBSDBackend.m \
  $(BUNDLED_PM_SRC)/GWOpenBSDBackend.m \
  $(BUNDLED_PM_SRC)/GWPackageManager.m

# Resource files (plists)
OnDemand_RESOURCE_FILES = \
  Resources/Info.plist Resources/Install.plist

# ARC throughout
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions
ADDITIONAL_OBJCFLAGS += -Wall -Wextra
ADDITIONAL_OBJCFLAGS += -Wno-nullability-completeness -Wno-unused-parameter
# PackageManager headers for bundled sources
ADDITIONAL_OBJCFLAGS += -I..

# Link with AppKit, Foundation, and libdispatch
OnDemand_FRAMEWORKS_DEPEND_UPON = AppKit Foundation
ADDITIONAL_LDFLAGS += -ldispatch

include $(GNUSTEP_MAKEFILES)/application.make

# Clean up bundled sources too
clean::
	rm -rf $(BUNDLED_PM_SRC)

# Manual copy of resource files into built app
$(APP_NAME).app/Resources/Info.plist: Resources/Info.plist
	mkdir -p $(@D) && cp $< $@

$(APP_NAME).app/Resources/Install.plist: Resources/Install.plist
	mkdir -p $(@D) && cp $< $@

all:: $(APP_NAME).app/Resources/Info.plist $(APP_NAME).app/Resources/Install.plist

system-install: $(APP_NAME).app
	sudo mkdir -p /System/Library/Services
	sudo cp -R $(APP_NAME).app /System/Library/Services/
	sudo chmod -R a+rX /System/Library/Services/$(APP_NAME).app
	@echo "Installed $(APP_NAME).app to /System/Library/Services/"
