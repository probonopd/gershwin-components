include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TOOL_NAME = UIBridgeServer

# X11 input automation injects synthetic pointer/key events via XSendEvent (no
# XTEST extension needed - works on every X server), plus the XKB client API
# which lives in libX11.  Discover the compiler/linker flags with pkg-config so
# this builds unchanged on both Linux and FreeBSD (where the X11 headers and
# libraries live under /usr/local).  Fall back to a plain -l flag if pkg-config
# is unavailable.
X11_PKGS := x11
X11_CFLAGS := $(shell pkg-config --cflags $(X11_PKGS) 2>/dev/null)
X11_LIBS := $(shell pkg-config --libs $(X11_PKGS) 2>/dev/null)
ifeq ($(strip $(X11_LIBS)),)
X11_LIBS := -lX11
endif

ADDITIONAL_INCLUDE_DIRS += $(X11_CFLAGS)
ADDITIONAL_LDFLAGS += $(X11_LIBS)
UIBridgeServer_OBJC_FILES = main.m X11Support.m LLDBController.m
UIBridgeServer_LIBRARIES = gnustep-base gnustep-gui objc

include $(GNUSTEP_MAKEFILES)/tool.make

# Install configuration
PREFIX ?= /
# Install configuration
# Prefer the GNUstep configured Tools directory when available; fall back to the conventional system location
BINDIR ?= $(GNUSTEP_SYSTEM_TOOLS)
ifeq ($(BINDIR),)
BINDIR := /System/Library/Tools
endif
LIBDIR ?= /usr/lib

after-install::
	mkdir -p $(DESTDIR)$(BINDIR)
	install -m 0755 obj/UIBridgeServer $(DESTDIR)$(BINDIR)/UIBridgeServer

after-uninstall::
	 rm -f $(DESTDIR)$(BINDIR)/UIBridgeServer

