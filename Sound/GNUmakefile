include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = Sound

Sound_OBJC_FILES = \
	SoundPane.m \
	SoundController.m \
	SoundModels.m \
	ALSABackend.m

# OSSBackend uses <sys/soundcard.h> (OSS), which OpenBSD does not provide
# (OpenBSD uses sndio). Build it everywhere except OpenBSD.
SOUND_UNAME_S := $(shell uname -s)
ifneq ($(SOUND_UNAME_S),OpenBSD)
Sound_OBJC_FILES += OSSBackend.m
endif

Sound_RESOURCE_FILES = Sound.png SoundInfo.plist
Sound_BUNDLE_LIBS = -lPreferencePanes
Sound_PRINCIPAL_CLASS = SoundPane

PREF_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# gmake install will install the bundle in /System/Library/Bundles/Sound.prefPane
# gmake uninstall will remove the bundle from /System/Library/Bundles/Sound.prefPane

# Custom install target that completely overrides built-in behavior
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(BUNDLE_NAME)$(BUNDLE_EXTENSION)
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(BUNDLE_NAME) to $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(DESTDIR)$(PREF_INSTALL_DIR)/; \
	else \
		echo "Installing $(BUNDLE_NAME) to $(PREF_INSTALL_DIR)"; \
		mkdir -p $(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(PREF_INSTALL_DIR)/; \
	fi

uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Removing $(BUNDLE_NAME) from $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		rm -rf $(DESTDIR)$(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
	else \
		echo "Removing $(BUNDLE_NAME) from $(PREF_INSTALL_DIR)"; \
		rm -rf $(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
	fi
