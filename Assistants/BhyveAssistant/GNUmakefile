include $(GNUSTEP_MAKEFILES)/common.make

# Application information
APP_NAME = BhyveAssistant
VERSION = 1.0

# Source files
BhyveAssistant_OBJC_FILES = \
	main.m \
	BhyveController.m \
	BhyveISOSelectionStep.m \
	BhyveConfigurationStep.m \
	BhyveRunningStep.m

# Resource files
BhyveAssistant_RESOURCE_FILES = \
	Resources/Bhyve_VM.png \
	Resources/Bhyve_VM.svg \
	Resources/en.lproj/Welcome.txt \
	Resources/en.lproj/ReadMe.txt \
	Resources/en.lproj/License.txt \
	Resources/en.lproj/Localizable.strings

# Required frameworks and libraries - use GNUstep naming (copy from working assistant)
BhyveAssistant_GUI_LIBS += -lgnustep-gui -lgnustep-base

# Compiler and linker flags - embed framework in bundle with proper FreeBSD rpath
BhyveAssistant_CPPFLAGS += -Wall -Wextra -Werror -O2 -I$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1/Headers
BhyveAssistant_LDFLAGS += -L$(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1 -lGSAssistantFramework -Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1'

include $(GNUSTEP_MAKEFILES)/application.make

# Copy framework into app bundle after building
after-all::
	@echo "Copying GSAssistantFramework into app bundle..."
	@mkdir -p $(APP_NAME).app/Frameworks
	@cp -R ../AssistantFramework/GSAssistantFramework.framework $(APP_NAME).app/Frameworks/
	@echo "Framework embedded in $(APP_NAME).app/Frameworks/"
	@echo "Fixing localized resource structure..."
	@mkdir -p $(APP_NAME).app/Resources/en.lproj
	@echo "Bhyve Assistant build complete"
