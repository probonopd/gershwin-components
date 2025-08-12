include $(GNUSTEP_MAKEFILES)/common.make

# Application configuration
APP_NAME = NetworkSetupAssistant

# Source files
NetworkSetupAssistant_OBJC_FILES = NetworkSetupAssistant.m NetworkSetupSteps.m

# Resource files
NetworkSetupAssistant_RESOURCE_FILES = \
	Resources/en.lproj/Welcome.txt \
	Resources/en.lproj/ReadMe.txt \
	Resources/en.lproj/License.txt \
	Resources/en.lproj/Localizable.strings \
	Resources/de.lproj/Welcome.txt \
	Resources/de.lproj/ReadMe.txt \
	Resources/de.lproj/License.txt \
	Resources/de.lproj/Localizable.strings

# Required frameworks and libraries - use GNUstep naming
NetworkSetupAssistant_GUI_LIBS += -lgnustep-gui -lgnustep-base

# Compiler and linker flags - embed framework in bundle
NetworkSetupAssistant_CPPFLAGS += -Wall -Wextra -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers
NetworkSetupAssistant_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework -Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1'

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

# Custom install target
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(APP_NAME)$(EXEEXT)
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(APP_NAME) to $(DESTDIR)$(GNUSTEP_SYSTEM_APPS)"; \
		mkdir -p $(DESTDIR)$(GNUSTEP_SYSTEM_APPS); \
		cp -R $(APP_NAME).app $(DESTDIR)$(GNUSTEP_SYSTEM_APPS)/; \
	else \
		echo "Installing $(APP_NAME) to $(GNUSTEP_SYSTEM_APPS)"; \
		mkdir -p $(GNUSTEP_SYSTEM_APPS); \
		sudo -A cp -R $(APP_NAME).app $(GNUSTEP_SYSTEM_APPS)/; \
	fi

# Override uninstall target to properly support DESTDIR
uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(APP_NAME) from $(DESTDIR)$(GNUSTEP_SYSTEM_APPS)"; \
		rm -rf $(DESTDIR)$(GNUSTEP_SYSTEM_APPS)/$(APP_NAME).app; \
	else \
		echo "Uninstalling $(APP_NAME) from $(GNUSTEP_SYSTEM_APPS)"; \
		sudo -A rm -rf $(GNUSTEP_SYSTEM_APPS)/$(APP_NAME).app; \
	fi

# Override built-in install targets to do nothing
internal-application-install::

internal-application-uninstall::
