include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

# Disable desktop file generation (pl2link tool not available)
RemoteDesktop_HAS_RESOURCE_BUNDLE = no
export GNUSTEP_CREATE_DESKTOP_RESOURCES = NO
RemoteDesktop_INSTALL_DESKTOP_FILES = no

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = RemoteDesktop
PACKAGE_NAME = RemoteDesktop
VERSION = 0.1

RemoteDesktop_PRINCIPAL_CLASS = NSApplication
RemoteDesktop_APPLICATION_ICON = RemoteDesktop.icns

RemoteDesktop_HEADER_FILES = \
	RemoteDesktop.h \
	VNCClient.h \
	VNCWindow.h \
	RDPClient.h \
	RDPWindow.h

RemoteDesktop_OBJC_FILES = \
	Main.m \
	RemoteDesktop.m \
	VNCClient.m \
	VNCWindow.m \
	RDPClient.m \
	RDPWindow.m

RemoteDesktop_RESOURCE_FILES = \
	RemoteDesktop.icns

RemoteDesktop_LOCALIZED_RESOURCE_FILES =

# Check for libvncclient
HAVE_VNCCLIENT := $(shell pkg-config --exists libvncclient 2>/dev/null && echo yes || echo no)

ifeq ($(HAVE_VNCCLIENT),no)
  # Try to find the library directly
  HAVE_VNCCLIENT := $(shell test -f /usr/lib/libvncclient.so -o -f /usr/local/lib/libvncclient.so && echo yes || echo no)
endif

ifeq ($(HAVE_VNCCLIENT),yes)
  RemoteDesktop_CPPFLAGS += -DHAVE_VNCCLIENT=1
  ifeq ($(shell pkg-config --exists libvncclient 2>/dev/null && echo yes || echo no),yes)
    RemoteDesktop_CPPFLAGS += $(shell pkg-config --cflags libvncclient)
    RemoteDesktop_LDFLAGS += $(shell pkg-config --libs libvncclient)
  else
    RemoteDesktop_LDFLAGS += -lvncclient
  endif
else
  $(warning libvncclient not found - VNC support will be disabled at runtime)
endif

# Check for FreeRDP
HAVE_FREERDP := $(shell pkg-config --exists freerdp2 2>/dev/null && echo yes || echo no)

ifeq ($(HAVE_FREERDP),no)
  HAVE_FREERDP := $(shell pkg-config --exists freerdp3 2>/dev/null && echo yes || echo no)
  ifeq ($(HAVE_FREERDP),yes)
    FREERDP_PKG = freerdp3
  endif
else
  FREERDP_PKG = freerdp2
endif

ifeq ($(HAVE_FREERDP),no)
  # Try to find the library directly
  HAVE_FREERDP := $(shell test -f /usr/lib/libfreerdp2.so -o -f /usr/local/lib/libfreerdp2.so && echo yes || echo no)
endif

ifeq ($(HAVE_FREERDP),yes)
  RemoteDesktop_CPPFLAGS += -DHAVE_FREERDP=1
  ifdef FREERDP_PKG
    RemoteDesktop_CPPFLAGS += $(shell pkg-config --cflags $(FREERDP_PKG) winpr2 2>/dev/null || pkg-config --cflags $(FREERDP_PKG) winpr3 2>/dev/null)
    RemoteDesktop_LDFLAGS += $(shell pkg-config --libs $(FREERDP_PKG) winpr2 2>/dev/null || pkg-config --libs $(FREERDP_PKG) winpr3 2>/dev/null)
  else
    RemoteDesktop_LDFLAGS += -lfreerdp2 -lwinpr2
  endif
else
  $(warning FreeRDP not found - RDP support will be disabled at runtime)
endif

# Common compiler flags
RemoteDesktop_CPPFLAGS += -Wall

# Link against GNUstep libraries
RemoteDesktop_GUI_LIBS += -lgnustep-gui -lgnustep-base

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)

# Remove desktop file if created (gnustep-make creates it even when disabled)
RemoteDesktop.app/Resources/RemoteDesktop.desktop:
	@echo "Skipping desktop file creation"
	@touch $@