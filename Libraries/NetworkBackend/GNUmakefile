include $(GNUSTEP_MAKEFILES)/common.make

LIBRARY_NAME = libNetworkBackend
VERSION = 1.0

libNetworkBackend_OBJC_FILES = \
	../../Network/NetworkModels.m \
	../../Network/NMBackend.m \
	../../Network/BSDBackend.m \
	CaptivePortalDetector.m

libNetworkBackend_HEADER_FILES = \
	../../Network/NetworkBackend.h \
	../../Network/NMBackend.h \
	../../Network/BSDBackend.h \
	CaptivePortalDetector.h

libNetworkBackend_INSTALL_HEADERS_DIR = NetworkBackend
libNetworkBackend_FRAMEWORKS_DEPEND_UPON = AppKit Foundation

# CaptivePortalDetector.m calls libcurl, so this library must link against it.
# Without this the .so still builds -- shared objects may carry undefined
# symbols -- but every executable that links -lNetworkBackend then fails.
# Linux toolchains have historically tolerated this; LLD on FreeBSD/NextBSD
# enforces --no-allow-shlib-undefined and rejects it, which is what stopped
# Menu.app from building on the BSD ISOs.
CURL_LIBS := $(shell pkg-config --libs libcurl 2>/dev/null || echo -lcurl)
CURL_CFLAGS := $(shell pkg-config --cflags libcurl 2>/dev/null)

libNetworkBackend_LIBRARIES_DEPEND_UPON += $(CURL_LIBS)
ADDITIONAL_CPPFLAGS += $(CURL_CFLAGS)

include $(GNUSTEP_MAKEFILES)/library.make

after-install::
	@rm -f $(GNUSTEP_SYSTEM_HEADERS)/NetworkBackend/NetworkController.h 2>/dev/null || true
	@rm -f $(GNUSTEP_SYSTEM_HEADERS)/NetworkBackend/NetworkPane.h 2>/dev/null || true
