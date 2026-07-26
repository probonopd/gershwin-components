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

#
# Whisper needs the whisper.cpp headers and libwhisper. None of the
# gershwin-developer requirement lists (Library/OSSupport/*.txt) provision it,
# so on a stock checkout -- CI included -- it is simply not present, and the
# component cannot be built at all.
#
# Probe for the header and skip this component with a clear message when it is
# missing, rather than failing the whole tree. This is an explicit, reported
# skip: it prints why it is skipping. That is deliberately different from
# swallowing the error with "|| true", which is what previously let this
# failure hide inside a green build.
#
WHISPER_PROBE_CFLAGS := -I/usr/local/include $(shell pkg-config --cflags whisper 2>/dev/null)

WHISPER_CC := $(CC)
ifeq ($(strip $(WHISPER_CC)),)
WHISPER_CC := $(shell command -v clang 2>/dev/null || command -v cc 2>/dev/null || command -v gcc 2>/dev/null)
endif

ifneq ($(strip $(WHISPER_CC)),)
WHISPER_AVAILABLE := $(shell printf '#include <whisper.h>\n' | \
	$(WHISPER_CC) $(WHISPER_PROBE_CFLAGS) -x c -E - >/dev/null 2>&1 && echo yes)
endif

ifneq ($(WHISPER_AVAILABLE),yes)

.PHONY: all build install clean distclean check

all build install clean distclean check:
	@echo "Whisper: SKIPPED -- whisper.h not found (whisper.cpp / libwhisper)."
	@echo "Whisper: install whisper.cpp, or add it to"
	@echo "Whisper:   gershwin-developer/Library/OSSupport/<os>.txt,"
	@echo "Whisper: then re-run to build this component."

else

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

# Sound headers (ALSABackend.h / OSSBackend.h) come from the sibling Sound
# directory. This must stay relative: an absolute /Developer/Library/Sources
# path only resolves on an installed Gershwin system, so CI and any checkout
# elsewhere failed with "'ALSABackend.h' file not found". Matches Menu's -I../Sound.
ADDITIONAL_INCLUDE_DIRS += -I/usr/local/include -I../Sound

#
# Link libraries
#
ADDITIONAL_GUI_LIBS += -lwhisper -lSoundBackend -ldispatch

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

endif
