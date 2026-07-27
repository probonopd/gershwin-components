include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = ColorAssistant
ColorAssistant_APPLICATION_ICON = Color.png
ColorAssistant_INFOPLIST_FILE = ColorAssistantInfo.plist

ColorAssistant_OBJC_FILES = \
	ColorAssistant.m \
	ColorAssistantPages.m \
	ProfileGenerator.m

ColorAssistant_RESOURCE_FILES = Color.png

ColorAssistant_CPPFLAGS += \
	-Wall -Wextra -Wno-unused-parameter -O2 \
	-fobjc-arc \
	-I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers

ColorAssistant_LDFLAGS += \
	-L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 \
	-lGSAssistantFramework \
	-Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1' \
	-Wl,--disable-new-dtags \
	-ldispatch -lX11 -lXrandr -llcms2

include $(GNUSTEP_MAKEFILES)/application.make

after-all::
	@echo "Copying GSAssistantFramework into app bundle..."
	@mkdir -p $(APP_NAME).app/Frameworks
	@if [ "$$(uname -s)" = "OpenBSD" ]; then rm -rf $(APP_NAME).app/Frameworks/GSAssistantFramework.framework; fi
	@cp -R ../AssistantFramework/GSAssistantFramework.framework $(APP_NAME).app/Frameworks/
	@echo "Framework embedded in $(APP_NAME).app/Frameworks/"
