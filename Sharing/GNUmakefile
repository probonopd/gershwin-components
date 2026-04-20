include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = Sharing

Sharing_OBJC_FILES = \
	SharingPane.m \
	SharingController.m \
	GSServiceDiscoveryManager.m

Sharing_RESOURCE_FILES = Sharing.png SharingInfo.plist
Sharing_BUNDLE_LIBS = -lPreferencePanes
Sharing_PRINCIPAL_CLASS = SharingPane

# For network operations
Sharing_LDFLAGS = -ldl

PREF_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
HELPER_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Tools
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# Build the sharing-helper as a standalone C program (no GNUstep dependency)
# This allows it to run with elevated privileges without needing GNUstep libraries in the path
HELPER_SRC = sharing-helper.c
HELPER_BIN = obj/sharing-helper

$(HELPER_BIN): $(HELPER_SRC)
	@mkdir -p obj
	$(CC) -O2 -Wall -o $@ $<

all:: $(HELPER_BIN)

clean::
	rm -f $(HELPER_BIN)

# Custom install target
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(HELPER_BIN)
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(BUNDLE_NAME) to $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(DESTDIR)$(PREF_INSTALL_DIR)/; \
		echo "Installing sharing-helper to $(DESTDIR)$(HELPER_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(HELPER_INSTALL_DIR); \
		cp $(HELPER_BIN) $(DESTDIR)$(HELPER_INSTALL_DIR)/sharing-helper; \
		chmod 755 $(DESTDIR)$(HELPER_INSTALL_DIR)/sharing-helper; \
		echo "Installing mDNS restoration script"; \
		cp gershwin-sharing-mdns.sh $(DESTDIR)$(HELPER_INSTALL_DIR)/; \
		chmod 755 $(DESTDIR)$(HELPER_INSTALL_DIR)/gershwin-sharing-mdns.sh; \
		echo "Installing systemd service (if systemd is present)"; \
		if [ -x "$(DESTDIR)/usr/bin/systemctl" ] || [ -x "$(DESTDIR)/bin/systemctl" ]; then \
			mkdir -p $(DESTDIR)/etc/systemd/system; \
			cp gershwin-sharing-mdns.service $(DESTDIR)/etc/systemd/system/; \
		fi; \
		echo "Creating state directory"; \
		mkdir -p $(DESTDIR)/var/lib/gershwin; \
	else \
		echo "Installing $(BUNDLE_NAME) to $(PREF_INSTALL_DIR)"; \
		mkdir -p $(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(PREF_INSTALL_DIR)/; \
		echo "Installing sharing-helper to $(HELPER_INSTALL_DIR)"; \
		mkdir -p $(HELPER_INSTALL_DIR); \
		cp $(HELPER_BIN) $(HELPER_INSTALL_DIR)/sharing-helper; \
		chmod 755 $(HELPER_INSTALL_DIR)/sharing-helper; \
		echo "Installing mDNS restoration script"; \
		cp gershwin-sharing-mdns.sh $(HELPER_INSTALL_DIR)/; \
		chmod 755 $(HELPER_INSTALL_DIR)/gershwin-sharing-mdns.sh; \
		echo "Installing systemd service (if systemd is present)"; \
		if command -v systemctl >/dev/null 2>&1; then \
			cp gershwin-sharing-mdns.service /etc/systemd/system/; \
			systemctl daemon-reload 2>/dev/null || true; \
			systemctl enable gershwin-sharing-mdns.service 2>/dev/null || true; \
			echo "Systemd service installed and enabled"; \
		else \
			echo "Systemd not found, service will not auto-start on boot"; \
		fi; \
		echo "Creating state directory"; \
		mkdir -p /var/lib/gershwin; \
		chmod 755 /var/lib/gershwin; \
	fi

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Removing $(BUNDLE_NAME) from $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		rm -rf $(DESTDIR)$(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
		echo "Removing sharing-helper from $(DESTDIR)$(HELPER_INSTALL_DIR)"; \
		rm -f $(DESTDIR)$(HELPER_INSTALL_DIR)/sharing-helper; \
		rm -f $(DESTDIR)$(HELPER_INSTALL_DIR)/gershwin-sharing-mdns.sh; \
		if [ -f "$(DESTDIR)/etc/systemd/system/gershwin-sharing-mdns.service" ]; then \
			rm -f $(DESTDIR)/etc/systemd/system/gershwin-sharing-mdns.service; \
		fi; \
	else \
		echo "Removing $(BUNDLE_NAME) from $(PREF_INSTALL_DIR)"; \
		rm -rf $(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
		echo "Removing sharing-helper from $(HELPER_INSTALL_DIR)"; \
		rm -f $(HELPER_INSTALL_DIR)/sharing-helper; \
		rm -f $(HELPER_INSTALL_DIR)/gershwin-sharing-mdns.sh; \
		if [ -f "/etc/systemd/system/gershwin-sharing-mdns.service" ]; then \
			systemctl stop gershwin-sharing-mdns.service 2>/dev/null || true; \
			systemctl disable gershwin-sharing-mdns.service 2>/dev/null || true; \
			rm -f /etc/systemd/system/gershwin-sharing-mdns.service; \
			systemctl daemon-reload 2>/dev/null || true; \
		fi; \
	fi

uninstall:: custom-uninstall
