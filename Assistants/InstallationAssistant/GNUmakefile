include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities

# Application configuration
APP_NAME = InstallationAssistant

# Source files
InstallationAssistant_OBJC_FILES = InstallationAssistant.m InstallationSteps.m

# Resource files
InstallationAssistant_RESOURCE_FILES = \
	Resources/en.lproj/Localizable.strings \
	Resources/de.lproj/Localizable.strings \
	Resources/installer-FreeBSD.sh \
	Resources/installer-Linux.sh

# Required frameworks and libraries - use GNUstep naming
InstallationAssistant_GUI_LIBS += -lgnustep-gui -lgnustep-base

# Compiler and linker flags - embed framework in bundle
InstallationAssistant_CPPFLAGS += -Wall -Wextra -Werror -O2 -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers
InstallationAssistant_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework -Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1' -ldispatch

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
	@echo "Making installer scripts executable..."
	@chmod +x $(APP_NAME).app/Resources/installer-FreeBSD.sh 2>/dev/null || true
	@chmod +x $(APP_NAME).app/Resources/installer-Linux.sh 2>/dev/null || true
	@echo "Installer scripts ready"

