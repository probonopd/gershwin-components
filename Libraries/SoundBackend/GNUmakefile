include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

LIBRARY_NAME = libSoundBackend
VERSION = 1.0

UNAME_S := $(shell uname -s)
libSoundBackend_OBJC_FILES = \
	../../Sound/SoundModels.m \
	../../Sound/WavScale.m \
	../../Sound/ALSABackend.m
ifneq ($(UNAME_S),OpenBSD)
libSoundBackend_OBJC_FILES += ../../Sound/OSSBackend.m
endif

libSoundBackend_HEADER_FILES = \
	../../Sound/SoundBackend.h \
	../../Sound/WavScale.h \
	../../Sound/ALSABackend.h \
	../../Sound/OSSBackend.h

libSoundBackend_INSTALL_HEADERS_DIR = SoundBackend
libSoundBackend_FRAMEWORKS_DEPEND_UPON = AppKit Foundation

include $(GNUSTEP_MAKEFILES)/library.make

after-install::
	@rm -f $(GNUSTEP_SYSTEM_HEADERS)/SoundBackend/SoundController.h 2>/dev/null || true
	@rm -f $(GNUSTEP_SYSTEM_HEADERS)/SoundBackend/SoundPane.h 2>/dev/null || true

