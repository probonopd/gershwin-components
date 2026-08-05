include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = drive_script

drive_script_OBJC_FILES = main.m DSLParser.m DSLLexer.m DSLQueryEngine.m DSLExecutor.m
drive_script_LIBRARIES = gnustep-base objc

include $(GNUSTEP_MAKEFILES)/tool.make

PREFIX ?= /
BINDIR ?= $(GNUSTEP_SYSTEM_TOOLS)
ifeq ($(BINDIR),)
BINDIR := /System/Library/Tools
endif

after-install::
	mkdir -p $(DESTDIR)$(BINDIR)
	install -m 0755 obj/drive_script $(DESTDIR)$(BINDIR)/drive_script

after-uninstall::
	rm -f $(DESTDIR)$(BINDIR)/drive_script