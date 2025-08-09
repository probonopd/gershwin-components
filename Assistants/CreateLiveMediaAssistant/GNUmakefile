include $(GNUSTEP_MAKEFILES)/common.make

# Application information
APP_NAME = CreateLiveMediaAssistant
VERSION = 1.0

# Source files
CreateLiveMediaAssistant_OBJC_FILES = \
	main.m \
	CLMController.m \
	CLMDiskUtility.m \
	CLMDownloader.m \
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
	Resources/check.png \
	Resources/cross.png \
	Resources/usbsuccess.svg

# Required frameworks and libraries - use GNUstep naming (copy from working assistant)
CreateLiveMediaAssistant_GUI_LIBS += -lgnustep-gui -lgnustep-base

# Compiler and linker flags - use absolute path and runtime path
CreateLiveMediaAssistant_CPPFLAGS += -Wall -Wextra -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers
CreateLiveMediaAssistant_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework -Wl,-rpath,$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1

include $(GNUSTEP_MAKEFILES)/application.make

# Post-installation tasks
after-install::
	@echo "Create Live Media Assistant has been installed successfully."

clean::
	@echo "Cleaning CreateLiveMediaAssistant..."
