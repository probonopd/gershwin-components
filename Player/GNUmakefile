#
# GNUmakefile for Player (Video & Audio Player)
#
ifeq ($(GNUSTEP_MAKEFILES),)
 GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)
endif
ifeq ($(GNUSTEP_MAKEFILES),)
 $(error You need to set GNUSTEP_MAKEFILES before compiling!)
endif

include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = Player
PACKAGE_NAME = Player
Player_PRINCIPAL_CLASS = NSApplication
Player_APPLICATION_ICON = Player.png

#
# Resource files
#
Player_RESOURCE_FILES = \
	Resources/Player.png

Player_LOCALIZED_RESOURCE_FILES = \
	Localizable.strings

Player_LANGUAGES = English


#
# Source files
#
Player_HEADER_FILES = \
	PlayerController.h \
	RadioStation.h \
	RadioBrowser.h \
	StreamPlayer.h \
	RadioManager.h \
	YTDLPBackend.h \
	PreferencesController.h

Player_OBJC_FILES = \
	PlayerController.m \
	RadioStation.m \
	RadioBrowser.m \
	StreamPlayer.m \
	RadioManager.m \
	YTDLPBackend.m \
	PreferencesController.m

Player_OBJC_FILES += Player_main.m

#
# AVFoundation framework - referenced from libs-av build tree
#
# Link with AVFoundation framework (installed system-wide via libs-av)
Player_GUI_LIBS += -lAVFoundation

#
# ItemFlow framework for album-art carousel
#
# On local builds ItemFlow is usually installed system-wide so -lItemFlow
# is found via default search paths.  On CI, ItemFlow is built in-tree but
# not yet installed — add a -L fallback so the linker finds it either way.
#
ITEMFLOW_SRC := $(CURDIR)/../ItemFlow
ITEMFLOW_LIB := $(ITEMFLOW_SRC)/ItemFlow.framework/Versions/Current
ADDITIONAL_INCLUDE_DIRS += -I$(ITEMFLOW_SRC)
ADDITIONAL_LDFLAGS += -L$(ITEMFLOW_LIB)
ADDITIONAL_GUI_LIBS += -lItemFlow -lGL -lGLU
# ItemFlow uses libdispatch internally; on FreeBSD the strict linker needs it explicitly.
ADDITIONAL_GUI_LIBS += -ldispatch

#
# FFmpeg and libao for internet radio streaming (StreamPlayer)
#
ADDITIONAL_INCLUDE_DIRS += $(shell pkg-config --cflags libavformat libavcodec libavutil libswresample libswscale)
ADDITIONAL_GUI_LIBS += $(shell pkg-config --libs libavformat libavcodec libavutil libswresample libswscale)
ADDITIONAL_GUI_LIBS += $(shell pkg-config --libs ao)

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/application.make

# Override desktop file creation — we don't need .desktop files for Gershwin.
$(APP_DIR)/Resources/$(GNUSTEP_INSTANCE).desktop:
	$(ECHO_NOTHING)echo "Desktop file generation disabled" > /dev/null$(END_ECHO)
	$(ECHO_NOTHING)touch $(APP_DIR)/Resources/$(GNUSTEP_INSTANCE).desktop; chmod a+x $(APP_DIR)/Resources/$(GNUSTEP_INSTANCE).desktop$(END_ECHO)


-include GNUmakefile.postamble
