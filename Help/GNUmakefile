# Help.app - native documentation viewer (Markdown, man, GSdoc)

include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Help
Help_MAIN_MODEL_FILE =

# Documentation viewer: lives next to Disk Utility in the utilities
# folder, not with end-user applications.
GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

Help_OBJC_FILES = Sources/main.m \
                  Sources/AppController.m \
                  Sources/Parsers/GSGSdocParser.m \
                  Sources/Core/GSHelpAppScanner.m \
                  Sources/Core/GSHelpCatalog.m \
                  Sources/Core/GSHelpDocument.m \
                  Sources/Core/GSHelpManLocator.m \
                  Sources/Core/GSHelpNode.m \
                  Sources/Core/GSHelpParserRegistry.m \
                  Sources/Core/GSHelpURL.m \
                  Sources/Parsers/GSHelpFormatDetector.m \
                  Sources/Parsers/GSManParser.m \
                  Sources/Parsers/GSTextParser.m \
                  Sources/Rendering/GSHelpRenderer.m \
                  Sources/UI/HelpWindowController.m \
                  Sources/Navigation/GSHelpHistory.m

# Markdown parser lands in parallel; compile it only once its header
# exists so this tree builds before and after that work arrives.
ifneq ($(wildcard Sources/Parsers/GSMarkdownParser.h),)
Help_OBJC_FILES += Sources/Parsers/GSMarkdownParser.m
endif

# Named after the app so NSApp picks it up as the application icon;
# the plist fills author/copyright/version in the About panel.
Help_RESOURCE_FILES = Help.png Resources/Info-gnustep.plist

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-runtime=gnustep-2.0
ADDITIONAL_INCLUDE_DIRS += -ISources/Core -ISources/Parsers -ISources/Rendering -ISources/UI -ISources/Navigation

# GSManParser decompresses gz/bz2/xz pages directly (SPEC 20) using
# __has_include-guarded codec readers, so link exactly those codecs
# whose dev files exist instead of assuming them (minimal Debian
# ships no libbz2-dev/liblzma-dev and would fail to link).
help_probe = echo 'int main(void){return 0;}' | $(CC) -x c - -include $(1).h -o /dev/null -l$(2) 2>/dev/null && echo yes

# The codecs must go into ADDITIONAL_GUI_LIBS, not *_LDFLAGS: gnustep-make
# puts LDFLAGS before the object files on the link line, and lld does not
# pull members from static archives scanned before the objects that
# reference them (OpenBSD ships bzip2/xz as .a only, so -lbz2/-llzma in
# LDFLAGS silently resolve nothing). ALL_LIBS lands after the objects,
# which is correct for static and shared libraries alike.
#
# The probes test compile AND link with a real symbol reference; a bare
# header check is not enough (some systems expose bzlib.h/lzma.h without
# usable libraries, which used to break the Help link on OpenBSD). The
# same result is handed to the compiler via -DGS_HAVE_*, so the source
# compiles in exactly the codecs that will be linked.
help_probe = printf 'int main(void){%s;return 0;}\n' '$(3)' | $(CC) -x c - -include $(1).h -o /dev/null -l$(2) 2>/dev/null && echo yes

ifneq ($(shell $(call help_probe,zlib,z,gzopen(0,0))),)
ADDITIONAL_GUI_LIBS += -lz
Help_OBJCFLAGS += -DGS_HAVE_ZLIB=1
endif
ifneq ($(shell $(call help_probe,bzlib,bz2,BZ2_bzDecompressInit(0,0,0))),)
ADDITIONAL_GUI_LIBS += -lbz2
Help_OBJCFLAGS += -DGS_HAVE_BZ2=1
endif
ifneq ($(shell $(call help_probe,lzma,lzma,lzma_code(0,0))),)
ADDITIONAL_GUI_LIBS += -llzma
Help_OBJCFLAGS += -DGS_HAVE_LZMA=1
endif

include $(GNUSTEP_MAKEFILES)/application.make

# The whole Gershwin stack ships in /System; never default to the LOCAL domain.
after-install::
	@echo "Installed Help.app to SYSTEM domain"
