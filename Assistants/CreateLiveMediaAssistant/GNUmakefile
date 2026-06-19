include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities

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
	CLMCompletionStep.m

# Resource files
CreateLiveMediaAssistant_RESOURCE_FILES = \
	Resources/Create_Live_Media.png \
	Resources/Create_Live_Media.svg \
	Resources/bgusb.png \
	Resources/usbsuccess.svg \
	Resources/en.lproj/Welcome.txt \
	Resources/en.lproj/ReadMe.txt \
	Resources/en.lproj/License.txt \
	Resources/en.lproj/Localizable.strings \
	Resources/de.lproj/Welcome.txt \
	Resources/de.lproj/ReadMe.txt \
	Resources/de.lproj/License.txt \
	Resources/de.lproj/Localizable.strings

# Required frameworks and libraries - use GNUstep naming (copy from working assistant)
CreateLiveMediaAssistant_GUI_LIBS += -lgnustep-gui -lgnustep-base

# Compiler and linker flags - embed framework in bundle with proper FreeBSD rpath
CreateLiveMediaAssistant_CPPFLAGS += -Wall -Wextra -fobjc-arc -Werror -O2 -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers
CreateLiveMediaAssistant_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework -Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1'
CreateLiveMediaAssistant_LDFLAGS += -ldispatch

include $(GNUSTEP_MAKEFILES)/application.make

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
