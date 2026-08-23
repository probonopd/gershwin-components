# Help.app - native documentation viewer (Markdown, man, GSdoc)

include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Help
Help_MAIN_MODEL_FILE =

Help_OBJC_FILES = Sources/main.m \
                  Sources/AppController.m \
                  Sources/Core/GSHelpAppScanner.m \
                  Sources/Core/GSHelpCatalog.m \
                  Sources/Core/GSHelpDocument.m \
                  Sources/Core/GSHelpManLocator.m \
                  Sources/Core/GSHelpNode.m \
                  Sources/Core/GSHelpParserRegistry.m \
                  Sources/Core/GSHelpURL.m \
                  Sources/Parsers/GSHelpFormatDetector.m \
                  Sources/Parsers/GSManParser.m \
                  Sources/Parsers/GSGSDocParser.m \
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

ifneq ($(shell $(call help_probe,zlib,z)),)
Help_LDFLAGS += -lz
endif
ifneq ($(shell $(call help_probe,bzlib,bz2)),)
Help_LDFLAGS += -lbz2
endif
ifneq ($(shell $(call help_probe,lzma,lzma)),)
Help_LDFLAGS += -llzma
endif

include $(GNUSTEP_MAKEFILES)/application.make

# The whole Gershwin stack ships in /System; never default to the LOCAL domain.
after-install::
	@echo "Installed Help.app to SYSTEM domain"
