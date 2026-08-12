include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TOOL_NAME = plistupdate

plistupdate_OBJC_FILES = \
	plistupdate.m

plistupdate_RESOURCE_FILES = 

# Man page installation
MANPAGE = plistupdate.1
INSTALL_MAN_DIR = $(GNUSTEP_DOC_MAN)/man1

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/tool.make

-include GNUmakefile.postamble

# Install man page
after-install::
	$(ECHO_NOTHING)if [ ! -d "$(INSTALL_MAN_DIR)" ]; then \
	  $(MKINSTALLDIRS) "$(INSTALL_MAN_DIR)"; \
	fi; \
	$(INSTALL_DATA) $(MANPAGE) "$(INSTALL_MAN_DIR)/$(MANPAGE)"$(END_ECHO)
	@echo "Installed $(MANPAGE) to $(INSTALL_MAN_DIR)"

# Uninstall man page
after-uninstall::
	$(ECHO_NOTHING)rm -f "$(INSTALL_MAN_DIR)/$(MANPAGE)"$(END_ECHO)
	@echo "Removed $(INSTALL_MAN_DIR)/$(MANPAGE)"

