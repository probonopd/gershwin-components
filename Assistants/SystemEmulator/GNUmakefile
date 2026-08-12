ifeq ($(GNUSTEP_MAKEFILES),)
 GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)
  ifeq ($(GNUSTEP_MAKEFILES),)
    $(warning Unable to obtain GNUSTEP_MAKEFILES setting from gnustep-config!)
    $(warning Perhaps gnustep-make is not properly installed.)
  endif
endif
ifeq ($(GNUSTEP_MAKEFILES),)
 $(error You need to set GNUSTEP_MAKEFILES before compiling!)
endif

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = SystemEmulator
VERSION = 0.1
PACKAGE_NAME = SystemEmulator

SystemEmulator_APPLICATION_ICON = SystemEmulator.png

SystemEmulator_RESOURCE_FILES = \
Resources/Info-gnustep.plist \
Resources/SystemEmulator.png

SystemEmulator_HEADER_FILES = \
Source/GSUTMConstants.h \
Source/GSUTMConfiguration.h \
Source/GSUTMConsoleController.h \
Source/GSUTMVirtualMachine.h \
Source/GSUTMMainWindowController.h \
Source/GSUTMAppDelegate.h

SystemEmulator_HEADER_FILES += \
Source/GSUTMAssistant.h

SystemEmulator_OBJC_FILES = \
Source/GSUTMConfiguration.m \
Source/GSUTMDisplayView.m \
Source/GSUTMConsoleController.m \
Source/GSUTMVirtualMachine.m \
Source/GSUTMMainWindowController.m \
Source/GSUTMAppDelegate.m \
Source/GSUTMAssistant.m \
Source/main.m

# Link against the AssistantFramework built as a sibling component, and
# embed it in the app bundle so the assistant runs without a system install.
GS_ASSISTANT_DIR := $(shell pwd)/../AssistantFramework/GSAssistantFramework.framework/Versions/1
SystemEmulator_CPPFLAGS += -I$(GS_ASSISTANT_DIR)/Headers
SystemEmulator_LDFLAGS += -L$(GS_ASSISTANT_DIR) -lGSAssistantFramework \
	-Wl,-rpath,'$$ORIGIN/Frameworks/GSAssistantFramework.framework/Versions/1' \
	-Wl,-rpath,/System/Library/Libraries
SystemEmulator_LDFLAGS += -lX11 -ldispatch

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/aggregate.make
include $(GNUSTEP_MAKEFILES)/application.make
-include GNUmakefile.postamble

