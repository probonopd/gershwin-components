include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = Build

Build_OBJC_FILES = \
	main.m \
	BuildController.m \
	BuildApplication.m \
	CatalogEntry.m \
	CatalogController.m \
	GWBuildPreflight.m

Build_HEADERS = \
	BuildController.h \
	BuildApplication.h \
	CatalogEntry.h \
	CatalogController.h \
	GWBuildPreflight.h

ADDITIONAL_GUI_LIBS += -ldispatch

# The PackageManager framework headers rely on nullability annotations; keep
# the app compile quiet about them.
ADDITIONAL_OBJCFLAGS += -Wno-nullability-completeness

# Link against the PackageManager framework, which is installed system-wide to
# /System/Library/Frameworks by 'gmake install' in the PackageManager/ dir.
# The app does not embed the framework; it resolves it via the system install.
ADDITIONAL_OBJCFLAGS += -I/System/Library/Headers
ADDITIONAL_LDFLAGS += -L/System/Library/Frameworks/PackageManager.framework/Versions/1 -lPackageManager
ADDITIONAL_LDFLAGS += -Wl,-rpath,/System/Library/Frameworks/PackageManager.framework/Versions/1

Build_APPLICATION_ICON = Build.png

Build_RESOURCE_FILES = \
	Resources/check.png \
	Resources/Blacklist.plist \
	Resources/GNUstep.info.plist \
	Resources/English.lproj \
	Resources/German.lproj \
	Info-gnustep.plist

include $(GNUSTEP_MAKEFILES)/application.make

