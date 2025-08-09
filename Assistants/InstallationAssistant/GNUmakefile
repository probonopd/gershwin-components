include $(GNUSTEP_MAKEFILES)/common.make

# Application configuration
APP_NAME = InstallationAssistant

# Source files
InstallationAssistant_OBJC_FILES = InstallationAssistant.m InstallationSteps.m

# Required frameworks and libraries - use GNUstep naming
InstallationAssistant_GUI_LIBS += -lgnustep-gui -lgnustep-base

# Compiler and linker flags
InstallationAssistant_CPPFLAGS += -Wall -Wextra
InstallationAssistant_LDFLAGS += -lGSAssistantFramework

include $(GNUSTEP_MAKEFILES)/application.make

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
