include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = SudoAskPass
SudoAskPass_OBJC_FILES = SudoAskPass.m
SudoAskPass_RESOURCE_FILES = 

include $(GNUSTEP_MAKEFILES)/application.make

GNUSTEP_APPS=$(GNUSTEP_SYSTEM_APPS)

after-install::
	ln -sf $(GNUSTEP_APPS)/$(APP_NAME).app/$(APP_NAME) $(GNUSTEP_SYSTEM_TOOLS)/$(APP_NAME)
