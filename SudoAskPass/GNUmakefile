include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = SudoAskPass
SudoAskPass_OBJC_FILES = SudoAskPass.m
SudoAskPass_RESOURCE_FILES = 

include $(GNUSTEP_MAKEFILES)/application.make

# Custom install target that completely overrides built-in behavior
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(APP_NAME).app
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(APP_NAME) to $(DESTDIR)$(GNUSTEP_SYSTEM_APPS)"; \
		mkdir -p $(DESTDIR)$(GNUSTEP_SYSTEM_APPS); \
		mkdir -p $(DESTDIR)$(GNUSTEP_SYSTEM_TOOLS); \
		cp -R $(APP_NAME).app $(DESTDIR)$(GNUSTEP_SYSTEM_APPS)/; \
		ln -sf $(GNUSTEP_SYSTEM_APPS)/$(APP_NAME).app/$(APP_NAME) $(DESTDIR)$(GNUSTEP_SYSTEM_TOOLS)/$(APP_NAME); \
	else \
		echo "Installing $(APP_NAME) to $(GNUSTEP_SYSTEM_APPS)"; \
		mkdir -p $(GNUSTEP_SYSTEM_APPS); \
		mkdir -p $(GNUSTEP_SYSTEM_TOOLS); \
		sudo -A cp -R $(APP_NAME).app $(GNUSTEP_SYSTEM_APPS)/; \
		sudo -A ln -sf $(GNUSTEP_SYSTEM_APPS)/$(APP_NAME).app/$(APP_NAME) $(GNUSTEP_SYSTEM_TOOLS)/$(APP_NAME); \
	fi

# Override uninstall target to properly support DESTDIR
uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(APP_NAME) from $(DESTDIR)$(GNUSTEP_SYSTEM_APPS)"; \
		rm -rf $(DESTDIR)$(GNUSTEP_SYSTEM_APPS)/$(APP_NAME).app; \
		rm -f $(DESTDIR)$(GNUSTEP_SYSTEM_TOOLS)/$(APP_NAME); \
	else \
		echo "Uninstalling $(APP_NAME) from $(GNUSTEP_SYSTEM_APPS)"; \
		sudo -A rm -rf $(GNUSTEP_SYSTEM_APPS)/$(APP_NAME).app; \
		sudo -A rm -f $(GNUSTEP_SYSTEM_TOOLS)/$(APP_NAME); \
	fi

# Override built-in install targets to do nothing
$(APP_NAME).install.application.variables::
	@true

shared-instance-application-install::
	@true

internal-application-install::
	@true

.PHONY: install uninstall
