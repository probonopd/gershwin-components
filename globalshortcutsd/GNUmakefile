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
BINDIR = $(GNUSTEP_SYSTEM_TOOLS)
MANDIR = $(PREFIX)/share/man/man1
DOCDIR = $(PREFIX)/share/doc/globalshortcutsd

# Install target (append our steps to the default install)
install::
	@echo "Installing globalshortcutsd extras..."
	install -d $(DESTDIR)$(DOCDIR)
	install -m 644 README.md $(DESTDIR)$(DOCDIR)/
	install -d $(DESTDIR)$(MANDIR)
	install -m 644 globalshortcutsd.1 $(DESTDIR)$(MANDIR)/
	@echo "Installation complete."

# Uninstall target (append our steps to the default uninstall)
uninstall::
	@echo "Uninstalling globalshortcutsd extras..."
	rm -f $(DESTDIR)$(MANDIR)/globalshortcutsd.1
	rm -rf $(DESTDIR)$(DOCDIR)
	@echo "Uninstallation complete."

# Clean target
clean::
	rm -f *~ *.core

.PHONY: install uninstall clean
