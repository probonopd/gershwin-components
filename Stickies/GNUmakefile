include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = Stickies

Stickies_OBJC_FILES = \
	main.m \
	StickiesAppDelegate.m \
	StickyNoteController.m \
	StickyNoteWindow.m \
	StickyNoteView.m \
	StickyNoteDocument.m \
	StickyNoteDatabase.m \
	StickyNoteColors.m

Stickies_HEADER_FILES = \
	StickiesAppDelegate.h \
	StickyNoteController.h \
	StickyNoteWindow.h \
	StickyNoteView.h \
	StickyNoteDocument.h \
	StickyNoteDatabase.h \
	StickyNoteColors.h

Stickies_RESOURCE_FILES = \
	Stickies.png

ADDITIONAL_GUI_LIBS += -ldispatch

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)
