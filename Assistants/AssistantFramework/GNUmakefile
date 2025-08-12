include $(GNUSTEP_MAKEFILES)/common.make

# Framework configuration
FRAMEWORK_NAME = GSAssistantFramework
VERSION = 1.0

# Prefer clang19 for compilation
CC ?= clang19

# Source files
GSAssistantFramework_OBJC_FILES = \
	GSAssistantWindow.m \
	GSAssistantSteps.m \
	GSAssistantUtilities.m \
	GSNetworkUtilities.m \
	GSDiskUtilities.m \
	GSSelectionStep.m \
	GSEnhancedProgressStep.m

# Header files to install
GSAssistantFramework_HEADER_FILES = \
	GSAssistantFramework.h \
	GSAssistantUtilities.h \
	GSNetworkUtilities.h \
	GSDiskUtilities.h \
	GSSelectionStep.h \
	GSEnhancedProgressStep.h

# Headers that should be included in the framework headers
# GSAssistantFramework_HEADER_FILES_INSTALL_DIR = /GSAssistantFramework

# Resource files to include in the framework
GSAssistantFramework_RESOURCE_FILES = \
	Resources/check.png \
	Resources/cross.png

# Manual copying approach for localized resources
after-install::
	@echo "Manually copying localized resources..."
	mkdir -p $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj
	mkdir -p $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj
	cp Resources/en.lproj/Localizable.strings $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/
	cp Resources/de.lproj/Localizable.strings $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/
	cp Resources/en.lproj/Welcome.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/
	cp Resources/de.lproj/Welcome.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/
	cp Resources/en.lproj/ReadMe.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/
	cp Resources/de.lproj/ReadMe.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/
	cp Resources/en.lproj/License.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/
	cp Resources/de.lproj/License.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/
	@echo "Localized resources copied to framework"

# Required frameworks and libraries
GSAssistantFramework_FRAMEWORKS_DEPEND_UPON = AppKit Foundation

# Compiler and linker flags
GSAssistantFramework_CPPFLAGS += -Wall -Wextra
GSAssistantFramework_OBJCFLAGS += -O2 -Werror

# Installation directory - build locally, don't install
FRAMEWORK_INSTALL_DIR = $(shell pwd)

include $(GNUSTEP_MAKEFILES)/framework.make

# Override all installation targets to do nothing - we'll embed in each assistant bundle
install::
	@echo "Framework built locally - no system installation"
	@echo "Framework available at: $(shell pwd)/$(FRAMEWORK_NAME).framework"

uninstall::
	@echo "No system installation to remove"

# Override built-in install targets to do nothing
internal-framework-install::
	@true

internal-framework-install_::
	@true

shared-instance-framework-install::
	@true

shared-instance-framework-install_::
	@true

# Development helpers
debug:
	@echo "Framework files:"
	@echo "  Source files: $(GSAssistantFramework_OBJC_FILES)"
	@echo "  Header files: $(GSAssistantFramework_HEADER_FILES)"
	@echo "  Framework location: $(shell pwd)/$(FRAMEWORK_NAME).framework"

clean::
	@echo "Cleaning $(FRAMEWORK_NAME)..."
	rm -rf $(FRAMEWORK_NAME).framework
	rm -rf obj
	rm -rf derived_src
