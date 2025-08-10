include $(GNUSTEP_MAKEFILES)/common.make

# This is a simple project that just installs files from the files/ directory
# No compilation needed, just file installation

PROJECT_NAME = initgfx

# Define all the files that need to be installed with their destination paths
INSTALL_FILES = \
	files/usr/local/share/drirc.d/01-freebsd-crocus-bugfix.conf \
	files/etc/initgfx_device.db \
	files/etc/rc.d/initgfx \
	files/etc/initgfx_xorg.cfg

# This project doesn't build anything, so we override the default targets
all::
	@echo "Nothing to build for $(PROJECT_NAME) - files are ready for installation"

clean::
	@echo "Nothing to clean for $(PROJECT_NAME)"

# Custom install target that completely overrides built-in behavior
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install:
	@echo "Installing $(PROJECT_NAME) files..."
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing to DESTDIR: $(DESTDIR)"; \
		for file in $(INSTALL_FILES); do \
			if [ -f "$$file" ]; then \
				dest_dir="$(DESTDIR)$$(dirname "$$file" | sed 's|^files||')"; \
				dest_file="$(DESTDIR)$$(echo "$$file" | sed 's|^files||')"; \
				echo "  Installing $$file to $$dest_file"; \
				mkdir -p "$$dest_dir"; \
				cp "$$file" "$$dest_file"; \
				chmod 644 "$$dest_file"; \
				if echo "$$file" | grep -q "/rc.d/"; then \
					chmod 755 "$$dest_file"; \
				fi; \
			else \
				echo "Warning: File $$file not found"; \
			fi; \
		done; \
	else \
		echo "Installing to system (requires sudo)"; \
		for file in $(INSTALL_FILES); do \
			if [ -f "$$file" ]; then \
				dest_dir="$$(dirname "$$file" | sed 's|^files||')"; \
				dest_file="$$(echo "$$file" | sed 's|^files||')"; \
				echo "  Installing $$file to $$dest_file"; \
				sudo -A mkdir -p "$$dest_dir"; \
				sudo -A cp "$$file" "$$dest_file"; \
				sudo -A chmod 644 "$$dest_file"; \
				if echo "$$file" | grep -q "/rc.d/"; then \
					sudo -A chmod 755 "$$dest_file"; \
				fi; \
			else \
				echo "Warning: File $$file not found"; \
			fi; \
		done; \
	fi
	@echo "$(PROJECT_NAME) installation completed"

# Override uninstall target to properly support DESTDIR
uninstall:: custom-uninstall

custom-uninstall:
	@echo "Uninstalling $(PROJECT_NAME) files..."
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling from DESTDIR: $(DESTDIR)"; \
		for file in $(INSTALL_FILES); do \
			dest_file="$(DESTDIR)$$(echo "$$file" | sed 's|^files||')"; \
			if [ -f "$$dest_file" ]; then \
				echo "  Removing $$dest_file"; \
				rm -f "$$dest_file"; \
			fi; \
		done; \
	else \
		echo "Uninstalling from system (requires sudo)"; \
		for file in $(INSTALL_FILES); do \
			dest_file="$$(echo "$$file" | sed 's|^files||')"; \
			if [ -f "$$dest_file" ]; then \
				echo "  Removing $$dest_file"; \
				sudo -A rm -f "$$dest_file"; \
			fi; \
		done; \
	fi
	@echo "$(PROJECT_NAME) uninstallation completed"

# Override built-in install targets to do nothing since we handle everything in custom-install
install.local.shared.headers::
	@true

install.local.shared.libraries::
	@true

install.local.shared.resources::
	@true

include $(GNUSTEP_MAKEFILES)/rules.make
