include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = Network

Network_OBJC_FILES = \
	NetworkPane.m \
	NetworkController.m \
	NetworkModels.m \
	NMBackend.m \
	BSDBackend.m

Network_RESOURCE_FILES = Network.png NetworkInfo.plist
Network_BUNDLE_LIBS = -lPreferencePanes
Network_PRINCIPAL_CLASS = NetworkPane

# For dlopen() used to load NetworkManager library. dlopen/dlsym are in libc on
# OpenBSD (no libdl to link against), so only add -ldl on other platforms.
NETWORK_UNAME_S := $(shell uname -s)
ifeq ($(NETWORK_UNAME_S),OpenBSD)
Network_LDFLAGS =
else
Network_LDFLAGS = -ldl
endif

PREF_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
HELPER_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Tools
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# Build the network-helper as a standalone C program (no GNUstep dependency)
# This allows it to run with elevated privileges without needing GNUstep libraries in the path
HELPER_SRC = network-helper.c
HELPER_BIN = obj/network-helper

$(HELPER_BIN): $(HELPER_SRC)
	@mkdir -p obj
	$(CC) -O2 -Wall -Wextra -Werror -o $@ $<

all:: $(HELPER_BIN)

clean::
	rm -f $(HELPER_BIN)

# gmake install will install the bundle in /System/Library/Bundles/Network.prefPane
# gmake uninstall will remove the bundle from /System/Library/Bundles/Network.prefPane

# Custom install target that completely overrides built-in behavior
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(HELPER_BIN)
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(BUNDLE_NAME) to $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(DESTDIR)$(PREF_INSTALL_DIR)/; \
		echo "Installing network-helper to $(DESTDIR)$(HELPER_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(HELPER_INSTALL_DIR); \
		cp $(HELPER_BIN) $(DESTDIR)$(HELPER_INSTALL_DIR)/; \
	else \
		echo "Installing $(BUNDLE_NAME) to $(PREF_INSTALL_DIR)"; \
		mkdir -p $(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(PREF_INSTALL_DIR)/; \
		echo "Installing network-helper to $(HELPER_INSTALL_DIR)"; \
		cp $(HELPER_BIN) $(HELPER_INSTALL_DIR)/; \
	fi

# Override uninstall target to properly support DESTDIR
uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(BUNDLE_NAME) from $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		rm -rf $(DESTDIR)$(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
		rm -f $(DESTDIR)$(HELPER_INSTALL_DIR)/network-helper; \
	else \
		echo "Uninstalling $(BUNDLE_NAME) from $(PREF_INSTALL_DIR)"; \
		rm -rf $(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
		rm -f $(HELPER_INSTALL_DIR)/network-helper; \
	fi

# Override built-in install targets to do nothing
$(BUNDLE_NAME).install.bundle.variables::
	@true

shared-instance-bundle-install::
	@true
