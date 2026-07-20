#
# GNUmakefile for Whisper (Speech-to-Text)
#
ifeq ($(GNUSTEP_MAKEFILES),)
 GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)
endif
ifeq ($(GNUSTEP_MAKEFILES),)
 $(error You need to set GNUSTEP_MAKEFILES before compiling!)
endif

include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = Whisper
PACKAGE_NAME = Whisper
Whisper_PRINCIPAL_CLASS = NSApplication
Whisper_APPLICATION_ICON = Whisper.png

#
# Resource files
#
Whisper_RESOURCE_FILES = \
	Resources/Info.plist \
	Resources/Info-gnustep.plist \
	Resources/Whisper.png \
	Resources/build-whisper.sh

#
# Header files
#
Whisper_HEADER_FILES = \
	WhisperController.h \
	WAudioLoader.h \
	WCapture.h

#
# Source files
#
Whisper_OBJC_FILES = \
	WhisperController.m \
	Whisper_main.m

Whisper_C_FILES = \
	WAudioLoader.c \
	WCapture.c

ADDITIONAL_INCLUDE_DIRS += -I/usr/local/include -I/Developer/Library/Sources/gershwin-components/Sound

#
# Link libraries
#
ADDITIONAL_GUI_LIBS += -lwhisper -lSoundBackend

# libcurl (cross-platform: pkg-config with fallback)
WHISPER_CURL_CFLAGS := $(shell pkg-config --cflags libcurl 2>/dev/null)
WHISPER_CURL_LIBS   := $(shell pkg-config --libs libcurl 2>/dev/null)
ifeq ($(strip $(WHISPER_CURL_LIBS)),)
WHISPER_CURL_CFLAGS :=
WHISPER_CURL_LIBS   := -lcurl
endif
ADDITIONAL_INCLUDE_DIRS += $(WHISPER_CURL_CFLAGS)
ADDITIONAL_GUI_LIBS += $(WHISPER_CURL_LIBS)

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/application.make

# Override desktop file creation
$(APP_DIR)/Resources/$(GNUSTEP_INSTANCE).desktop:
	$(ECHO_NOTHING)echo "Desktop file generation disabled" > /dev/null$(END_ECHO)
	$(ECHO_NOTHING)touch $(APP_DIR)/Resources/$(GNUSTEP_INSTANCE).desktop; chmod a+x $(APP_DIR)/Resources/$(GNUSTEP_INSTANCE).desktop$(END_ECHO)

-include GNUmakefile.postamble
