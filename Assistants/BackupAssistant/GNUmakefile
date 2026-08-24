include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

# Application configuration
APP_NAME = BackupAssistant

# Source files
BackupAssistant_OBJC_FILES = \
	main.m \
	BAController.m \
	BAZFSUtility.m \
	BAIntroStep.m \
	BADiskSelectionStep.m \
	BAOperationSelectionStep.m \
	BAConfigurationStep.m \
	BAProgressStep.m \
	BACompletionStep.m

# Resource files
BackupAssistant_RESOURCE_FILES = \
	Resources/backup_icon.png \
	Resources/backup_watermark.png \
	Resources/en.lproj/Localizable.strings

# Required frameworks and libraries - use GNUstep naming
BackupAssistant_GUI_LIBS += -lgnustep-gui -lgnustep-base

# Compiler and linker flags - embed framework in bundle
BackupAssistant_CPPFLAGS += -Wall -Wextra -fobjc-arc -Werror -Wno-unused-parameter -O2 -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers
BackupAssistant_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework -Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1'
BackupAssistant_LDFLAGS += -ldispatch

include $(GNUSTEP_MAKEFILES)/application.make

# Copy framework into app bundle after building
after-all::
	@echo "Copying GSAssistantFramework into app bundle..."
	@mkdir -p $(APP_NAME).app/Frameworks
	@cp -R ../AssistantFramework/GSAssistantFramework.framework $(APP_NAME).app/Frameworks/
	@echo "Framework embedded in $(APP_NAME).app/Frameworks/"
	@echo "Fixing localized resource structure..."
	@mkdir -p $(APP_NAME).app/Resources/en.lproj
	@# Remove any flattened Localizable.strings; GNUstep may have overwritten it.
	@rm -f $(APP_NAME).app/Resources/Localizable.strings
	@# Explicitly copy each localization from source to guarantee correct content.
	@cp Resources/en.lproj/Localizable.strings $(APP_NAME).app/Resources/en.lproj/
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
		cp -R $(APP_NAME).app $(GNUSTEP_SYSTEM_APPS)/; \
	fi

# Create launch script for easy execution
launch:
	@echo '#!/bin/sh' > launch.sh
	@echo 'cd "$(shell pwd)"' >> launch.sh
	@echo './$(APP_NAME).app/$(APP_NAME)' >> launch.sh
	@chmod +x launch.sh
	@echo "Created launch script: launch.sh"

