include $(GNUSTEP_MAKEFILES)/common.make

# Application information
APP_NAME = CreateLiveMediaAssistant
VERSION = 1.0

# Source files
CreateLiveMediaAssistant_OBJC_FILES = \
	main.m \
	CLMController.m \
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
CreateLiveMediaAssistant_CPPFLAGS += -Wall -Wextra -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers
CreateLiveMediaAssistant_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework -Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1'

include $(GNUSTEP_MAKEFILES)/application.make

# Copy framework into app bundle after building
after-all::
	@echo "Copying GSAssistantFramework into app bundle..."
	@mkdir -p $(APP_NAME).app/Frameworks
	@cp -R ../AssistantFramework/GSAssistantFramework.framework $(APP_NAME).app/Frameworks/
	@echo "Framework embedded in $(APP_NAME).app/Frameworks/"
	@echo "Fixing localized resource structure..."
	@mkdir -p $(APP_NAME).app/Resources/en.lproj
	@mkdir -p $(APP_NAME).app/Resources/de.lproj
	@# Move any flattened Localizable.strings to proper .lproj directories
	@if [ -f $(APP_NAME).app/Resources/Localizable.strings ]; then \
		mv $(APP_NAME).app/Resources/Localizable.strings $(APP_NAME).app/Resources/en.lproj/; \
	fi
	@cp Resources/de.lproj/Localizable.strings $(APP_NAME).app/Resources/de.lproj/ 2>/dev/null || true
	@echo "Localized resource structure fixed"

# Post-installation tasks
after-install::
	@echo "Create Live Media Assistant has been installed successfully."

clean::
	@echo "Cleaning CreateLiveMediaAssistant..."
