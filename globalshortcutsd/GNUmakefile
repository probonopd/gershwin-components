include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = globalshortcutsd

globalshortcutsd_OBJC_FILES = globalshortcutsd.m

# Link with X11 libraries
globalshortcutsd_LDFLAGS += -lX11

# Include X11 headers
globalshortcutsd_CPPFLAGS += -I/usr/include/X11 -I/usr/local/include

# Compiler flags for production builds
globalshortcutsd_OBJCFLAGS += -Wall -Wextra -Werror -O2

include $(GNUSTEP_MAKEFILES)/tool.make

# Installation directories
BINDIR = $(GNUSTEP_SYSTEM_TOOLS)
PREFIX ?= /usr/local
MANDIR = $(PREFIX)/share/man/man1
DOCDIR = $(PREFIX)/share/doc/globalshortcutsd

# Install target (append our steps to the default install)
install::
	@echo "Installing globalshortcutsd extras..."
	@if [ -n "$(DESTDIR)" ]; then \
		install -d $(DESTDIR)$(BINDIR); \
		install -m 755 $(GNUSTEP_OBJ_DIR)/globalshortcutsd $(DESTDIR)$(BINDIR)/; \
		install -d $(DESTDIR)$(DOCDIR); \
		install -m 644 README.md $(DESTDIR)$(DOCDIR)/; \
		install -d $(DESTDIR)$(MANDIR); \
		install -m 644 globalshortcutsd.1 $(DESTDIR)$(MANDIR)/; \
	else \
		sudo -A install -d $(BINDIR); \
		sudo -A install -m 755 $(GNUSTEP_OBJ_DIR)/globalshortcutsd $(BINDIR)/; \
		sudo -A install -d $(DOCDIR); \
		sudo -A install -m 644 README.md $(DOCDIR)/; \
		sudo -A install -d $(MANDIR); \
		sudo -A install -m 644 globalshortcutsd.1 $(MANDIR)/; \
	fi
	@echo "Installation complete."

# Uninstall target (append our steps to the default uninstall)
uninstall::
	@echo "Uninstalling globalshortcutsd extras..."
	@if [ -n "$(DESTDIR)" ]; then \
		rm -f $(DESTDIR)$(BINDIR)/globalshortcutsd; \
		rm -f $(DESTDIR)$(MANDIR)/globalshortcutsd.1; \
		rm -rf $(DESTDIR)$(DOCDIR); \
	else \
		sudo -A rm -f $(BINDIR)/globalshortcutsd; \
		sudo -A rm -f $(MANDIR)/globalshortcutsd.1; \
		sudo -A rm -rf $(DOCDIR); \
	fi
	@echo "Uninstallation complete."

# Clean target
clean::
	rm -f *~ *.core

.PHONY: install uninstall clean
