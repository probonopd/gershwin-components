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

include $(GNUSTEP_MAKEFILES)/library.make

after-install::
	@rm -f $(GNUSTEP_SYSTEM_HEADERS)/NetworkBackend/NetworkController.h 2>/dev/null || true
	@rm -f $(GNUSTEP_SYSTEM_HEADERS)/NetworkBackend/NetworkPane.h 2>/dev/null || true
