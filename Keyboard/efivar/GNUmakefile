include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = efivar

efivar_OBJC_FILES = \
	main.m \
	EfiVar.m \
	EfiVarLinux.m \
	EfiVarFreeBSD.m

efivar_OBJCFLAGS = -Wall -Wextra -Werror

# Man page
MANPAGE = efivar.1
INSTALL_MAN_DIR = $(GNUSTEP_DOC_MAN)/man1

# Install to /System/Library/Tools
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/tool.make

-include GNUmakefile.postamble

after-install::
	$(ECHO_NOTHING)if [ ! -d "$(INSTALL_MAN_DIR)" ]; then \
	  $(MKINSTALLDIRS) "$(INSTALL_MAN_DIR)"; \
	fi; \
	$(INSTALL_DATA) $(MANPAGE) "$(INSTALL_MAN_DIR)/$(MANPAGE)"$(END_ECHO)
	@echo "Installed $(MANPAGE) to $(INSTALL_MAN_DIR)"

after-uninstall::
	$(ECHO_NOTHING)rm -f "$(INSTALL_MAN_DIR)/$(MANPAGE)"$(END_ECHO)
	@echo "Removed $(INSTALL_MAN_DIR)/$(MANPAGE)"
