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

# GSManParser decompresses gz/bz2/xz pages directly (SPEC 20).
ifeq ($(shell uname -s),Linux)
Help_LDFLAGS += -lz -lbz2 -llzma
else ifeq ($(shell uname -s),FreeBSD)
Help_LDFLAGS += -lz -lbz2 -llzma
else ifeq ($(shell uname -s),OpenBSD)
Help_LDFLAGS += -lz -lbz2 -llzma
endif

include $(GNUSTEP_MAKEFILES)/application.make

# The whole Gershwin stack ships in /System; never default to the LOCAL domain.
after-install::
	@echo "Installed Help.app to SYSTEM domain"
