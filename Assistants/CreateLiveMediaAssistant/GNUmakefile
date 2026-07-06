include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

# Application information
APP_NAME = CreateLiveMediaAssistant
VERSION = 1.0

# Source files
CreateLiveMediaAssistant_OBJC_FILES = \
	main.m \
	CLMController.m \
	CLMConstants.m \
	CLMDiskUtility.m \
	CLMGitHubAPI.m \
	CLMIntroStep.m \
	CLMImageSelectionStep.m \
	CLMDiskSelectionStep.m \
	CLMInstallationStep.m \
	CLMCompletionStep.m \
	CLMBlockDeviceWriter.m \
	CLMStreamDownloader.m \
	CLMArchiveExtractor.m \
	CLMStreamOperation.m

# Resource files
CreateLiveMediaAssistant_RESOURCE_FILES = \
	Resources/Create_Live_Media.png \
	Resources/Create_Live_Media.svg \
	Resources/bgusb.png \
	Resources/usbsuccess.svg \
	Resources/en.lproj/Localizable.strings \
	Resources/de.lproj/Localizable.strings

# Required frameworks and libraries - use GNUstep naming (copy from working assistant)
CreateLiveMediaAssistant_GUI_LIBS += -lgnustep-gui -lgnustep-base

# libcurl + libarchive: prefer pkg-config, but fall back to explicit linkage.
# On FreeBSD, base libarchive ships no .pc file and curl lives under /usr/local,
# so `pkg-config --libs` silently expands to nothing (the 2>/dev/null hides the
# failure) and the curl_*/archive_* symbols end up undefined at link time.
CLM_DEP_CFLAGS := $(shell pkg-config --cflags libcurl libarchive 2>/dev/null)
CLM_DEP_LIBS   := $(shell pkg-config --libs libcurl libarchive 2>/dev/null)
ifeq ($(strip $(CLM_DEP_LIBS)),)
CLM_DEP_CFLAGS := -I/usr/local/include
CLM_DEP_LIBS   := -L/usr/local/lib -lcurl -larchive
endif

# Compiler and linker flags - embed framework in bundle with proper rpath
CreateLiveMediaAssistant_CPPFLAGS += -Wall -Wextra -fobjc-arc -Werror -Wno-unused-parameter -O2 -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers $(CLM_DEP_CFLAGS)
CreateLiveMediaAssistant_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework $(CLM_DEP_LIBS) -Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1' -Wl,-rpath,/System/Library/Libraries
CreateLiveMediaAssistant_LDFLAGS += -ldispatch

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)

# Copy framework into app bundle after building
after-all::
	@echo "Copying GSAssistantFramework into app bundle..."
	@mkdir -p $(APP_NAME).app/Frameworks
	@# after-all runs more than once. On OpenBSD, cp cannot overwrite the
	@# already-embedded framework's symlinked Versions/Current on the second
	@# pass, so remove the prior copy first there only. Linux/FreeBSD cp handle
	@# the re-copy fine, so their behaviour is unchanged.
	@if [ "$$(uname -s)" = "OpenBSD" ]; then rm -rf $(APP_NAME).app/Frameworks/GSAssistantFramework.framework; fi
	@cp -R ../AssistantFramework/GSAssistantFramework.framework $(APP_NAME).app/Frameworks/
	@echo "Framework embedded in $(APP_NAME).app/Frameworks/"
	@echo "Fixing localized resource structure..."
	@mkdir -p $(APP_NAME).app/Resources/en.lproj
	@mkdir -p $(APP_NAME).app/Resources/de.lproj
	@# Remove any flattened Localizable.strings; GNUstep may have overwritten it
	@# with the last-listed language (de), so we cannot rely on its contents.
	@rm -f $(APP_NAME).app/Resources/Localizable.strings
	@# Explicitly copy each localization from source to guarantee correct content.
	@cp Resources/en.lproj/Localizable.strings $(APP_NAME).app/Resources/en.lproj/
	@cp Resources/de.lproj/Localizable.strings $(APP_NAME).app/Resources/de.lproj/
	@echo "Localized resource structure fixed"

clean::
	@echo "Cleaning CreateLiveMediaAssistant..."
