include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = globalshortcutsd

globalshortcutsd_OBJC_FILES = globalshortcutsd.m

# Link with X11 libraries
globalshortcutsd_LDFLAGS += -lX11

# Include X11 headers
globalshortcutsd_CPPFLAGS += -I/usr/include/X11 -I/usr/local/include

# Use clang19 as specified in instructions
CC = clang19
OBJC = clang19

# Compiler flags for production builds
globalshortcutsd_OBJCFLAGS += -Wall -Wextra -Werror -O2

include $(GNUSTEP_MAKEFILES)/tool.make

# Installation directories
PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man/man1
DOCDIR = $(PREFIX)/share/doc/globalshortcutsd

# Install target
install-daemon: all
	@echo "Installing globalshortcutsd..."
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 $(GNUSTEP_OBJ_DIR)/globalshortcutsd $(DESTDIR)$(BINDIR)/
	install -d $(DESTDIR)$(DOCDIR)
	install -m 644 README.md $(DESTDIR)$(DOCDIR)/
	@echo "Installation complete."
	@echo "Create a configuration file at ~/.globalshortcutsrc"
	@echo "Example configuration:"
	@echo "  ctrl+shift+t=xterm"
	@echo "  ctrl+shift+f=firefox"
	@echo ""
	@echo "Start the daemon with: globalshortcutsd"
	@echo "For verbose output: globalshortcutsd -v"

# Uninstall target
uninstall-daemon:
	@echo "Uninstalling globalshortcutsd..."
	rm -f $(DESTDIR)$(BINDIR)/globalshortcutsd
	rm -rf $(DESTDIR)$(DOCDIR)
	@echo "Uninstallation complete."

# Clean target
clean::
	rm -f *~ *.core

.PHONY: install-daemon uninstall-daemon clean
