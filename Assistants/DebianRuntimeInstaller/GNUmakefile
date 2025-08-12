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
	Resources/en.lproj/Welcome.txt \
	Resources/en.lproj/ReadMe.txt \
	Resources/en.lproj/License.txt \
	Resources/en.lproj/Localizable.strings \
	Resources/de.lproj/Welcome.txt \
	Resources/de.lproj/ReadMe.txt \
	Resources/de.lproj/License.txt \
	Resources/de.lproj/Localizable.strings

# Required frameworks and libraries - use GNUstep naming (copy from working assistant)
DebianRuntimeInstaller_GUI_LIBS += -lgnustep-gui -lgnustep-base

# Compiler and linker flags - embed framework in bundle
DebianRuntimeInstaller_CPPFLAGS += -Wall -Wextra -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers
DebianRuntimeInstaller_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework -Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1'

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
	@echo "Debian Runtime Installer has been installed successfully."

clean::
	@echo "Cleaning DebianRuntimeInstaller..."
