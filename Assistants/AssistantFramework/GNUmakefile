include $(GNUSTEP_MAKEFILES)/common.make

# Framework configuration
FRAMEWORK_NAME = GSAssistantFramework
VERSION = 1.0

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
GSAssistantFramework_HEADER_FILES_INSTALL_DIR = /GSAssistantFramework

# Resource files to include in the framework
GSAssistantFramework_RESOURCE_FILES = \
	Resources/check.png \
	Resources/cross.png

# Required frameworks and libraries
GSAssistantFramework_FRAMEWORKS_DEPEND_UPON = AppKit Foundation

# Compiler and linker flags
GSAssistantFramework_CPPFLAGS += -Wall -Wextra

# Installation directory
FRAMEWORK_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Frameworks

include $(GNUSTEP_MAKEFILES)/framework.make

# Manual copying approach for localized resources
after-install::
	@echo "Manually copying localized resources..."
	mkdir -p $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj
	mkdir -p $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj
	if [ -f Resources/en.lproj/Localizable.strings ]; then cp Resources/en.lproj/Localizable.strings $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/; fi
	if [ -f Resources/de.lproj/Localizable.strings ]; then cp Resources/de.lproj/Localizable.strings $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/; fi
	if [ -f Resources/en.lproj/Welcome.txt ]; then cp Resources/en.lproj/Welcome.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/; fi
	if [ -f Resources/de.lproj/Welcome.txt ]; then cp Resources/de.lproj/Welcome.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/; fi
	if [ -f Resources/en.lproj/ReadMe.txt ]; then cp Resources/en.lproj/ReadMe.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/; fi
	if [ -f Resources/de.lproj/ReadMe.txt ]; then cp Resources/de.lproj/ReadMe.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/; fi
	if [ -f Resources/en.lproj/License.txt ]; then cp Resources/en.lproj/License.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/; fi
	if [ -f Resources/de.lproj/License.txt ]; then cp Resources/de.lproj/License.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/; fi
	@echo "Localized resources copied to framework"

# Custom install target that completely overrides built-in behavior
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(FRAMEWORK_NAME).framework
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(FRAMEWORK_NAME) to $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(FRAMEWORK_INSTALL_DIR); \
		cp -R $(FRAMEWORK_NAME).framework $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)/; \
	else \
		echo "Installing $(FRAMEWORK_NAME) to $(FRAMEWORK_INSTALL_DIR)"; \
		mkdir -p $(FRAMEWORK_INSTALL_DIR); \
		sudo -A cp -R $(FRAMEWORK_NAME).framework $(FRAMEWORK_INSTALL_DIR)/; \
	fi

# Override uninstall target to properly support DESTDIR
uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(FRAMEWORK_NAME) from $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)"; \
		rm -rf $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
	else \
		echo "Uninstalling $(FRAMEWORK_NAME) from $(FRAMEWORK_INSTALL_DIR)"; \
		sudo -A rm -rf $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
	fi

# Override built-in install targets to do nothing
internal-framework-install::
	@true

shared-instance-framework-install::
	@true

# Development helpers
debug:
	@echo "Framework files:"
	@echo "  Source files: $(GSAssistantFramework_OBJC_FILES)"
	@echo "  Header files: $(GSAssistantFramework_HEADER_FILES)"
	@echo "  Install dir: $(FRAMEWORK_INSTALL_DIR)"
	@echo "  DESTDIR: $(DESTDIR)"

clean::
	@echo "Cleaning $(FRAMEWORK_NAME)..."
	rm -rf $(FRAMEWORK_NAME).framework
	rm -rf obj
	rm -rf derived_src

# Test target
test: TestNewLayout
	@echo "Running layout test..."
	@echo "Note: Run './obj/TestNewLayout' to test both layout styles"
