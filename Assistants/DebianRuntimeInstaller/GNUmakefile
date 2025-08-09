include $(GNUSTEP_MAKEFILES)/common.make

# Application information
APP_NAME = DebianRuntimeInstaller
VERSION = 1.0

# Source files
DebianRuntimeInstaller_OBJC_FILES = \
	main.m \
	DRIController.m \
	DRIDownloader.m \
	DRIGitHubAPI.m \
	DRIInstaller.m \
	DRIIntroStep.m \
	DRIImageSelectionStep.m \
	DRIConfirmationStep.m \
	DRIInstallationStep.m \
	DRICompletionStep.m

# Resource files
DebianRuntimeInstaller_RESOURCE_FILES = \
	Resources/debian \
	Resources/install-debian-runtime.png \
	Resources/background.png \
	Resources/check.png \
	Resources/cross.png

# Required frameworks and libraries - use GNUstep naming (copy from working assistant)
DebianRuntimeInstaller_GUI_LIBS += -lgnustep-gui -lgnustep-base

# Compiler and linker flags - use absolute path and runtime path
DebianRuntimeInstaller_CPPFLAGS += -Wall -Wextra -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers
DebianRuntimeInstaller_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework -Wl,-rpath,$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1

include $(GNUSTEP_MAKEFILES)/application.make

# Post-installation tasks
after-install::
	@echo "Debian Runtime Installer has been installed successfully."

clean::
	@echo "Cleaning DebianRuntimeInstaller..."
