include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = Phone

Phone_OBJC_FILES = \
	main.m \
	AppDelegate.m \
	MainWindowController.m \
	PreferencesController.m \
	SIPManager.m

ADDITIONAL_OBJCFLAGS = -fobjc-arc

# Try to use pkg-config for libre/baresip where possible. This keeps the
# Makefile distribution-agnostic and respects the README (GTK/Pulse are
# optional and not required for a minimal Phone build).
PKG_LIBRE := $(shell pkg-config --exists libre >/dev/null 2>&1 && echo yes)
ifeq ($(PKG_LIBRE),yes)
ADDITIONAL_OBJCFLAGS += $(shell pkg-config --cflags libre)
# Prefer linking via pkg-config so the correct linker flags are used
ADDITIONAL_GUI_LIBS += $(shell pkg-config --libs libre baresip 2>/dev/null)
else
# Fall back to searching /usr/local for headers and shared libs
ifneq ($(wildcard /usr/local/include/re/re.h),)
ADDITIONAL_OBJCFLAGS += -I/usr/local/include
ADDITIONAL_GUI_LIBS += -lbaresip -lre
else
# No libre headers — do NOT provide a stub; require libre/baresip to build.
$(warning libre/baresip not found: Phone will fail to build without libre/baresip)
endif
endif

# Minimal common libraries (X11/PNG/ALSA are reasonable minimal defaults; GUI and
# optional audio backends such as Pulse/PipeWire/GTK are intentionally not required
# by default — install them only if you need those features or Baresip modules).
COMMON_LIBS = -lm -ldl -lpthread -ldispatch
ADDITIONAL_GUI_LIBS += $(COMMON_LIBS) -lX11 -lpng -lasound

include $(GNUSTEP_MAKEFILES)/application.make

.PHONY: copy-tones

after-all:: copy-tones

copy-tones:
	mkdir -p Phone.app/Resources
	@if ls /usr/local/share/baresip/*.wav >/dev/null 2>&1; then \
		cp /usr/local/share/baresip/*.wav Phone.app/Resources/; \
	fi

