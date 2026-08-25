# Non-GUI conversion/render dump tool: parses documents with the same
# registry + renderer as the app and prints annotated output, so whole
# man/md/gsdoc corpora can be screened from a terminal.

include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = renderdump

# The renderer pulls in AppKit; the codecs must land after the objects
# (see the app GNUmakefile for why plain LDFLAGS fails with lld).
NEEDS_GUI = yes

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-runtime=gnustep-2.0
ADDITIONAL_INCLUDE_DIRS += -I../../Sources/Core -I../../Sources/Parsers \
                           -I../../Sources/Rendering

# Same codec gating as the app build: link exactly the decompressors
# that compile AND link here, and compile the parser with matching
# GS_HAVE_* defines.
help_probe = printf 'int main(void){%s;return 0;}\n' '$(3)' | $(CC) -x c - -include $(1).h -o /dev/null -l$(2) 2>/dev/null && echo yes

CODEC_LIBS =
ifneq ($(shell $(call help_probe,zlib,z,gzopen(0,0))),)
CODEC_LIBS += -lz
renderdump_OBJCFLAGS += -DGS_HAVE_ZLIB=1
endif
ifneq ($(shell $(call help_probe,bzlib,bz2,BZ2_bzDecompressInit(0,0,0))),)
CODEC_LIBS += -lbz2
renderdump_OBJCFLAGS += -DGS_HAVE_BZ2=1
endif
ifneq ($(shell $(call help_probe,lzma,lzma,lzma_code(0,0))),)
CODEC_LIBS += -llzma
renderdump_OBJCFLAGS += -DGS_HAVE_LZMA=1
endif

renderdump_OBJC_FILES = renderdump.m \
                        ../../Sources/Core/GSHelpDocument.m \
                        ../../Sources/Core/GSHelpNode.m \
                        ../../Sources/Core/GSHelpParserRegistry.m \
                        ../../Sources/Core/GSHelpURL.m \
                        ../../Sources/Parsers/GSGSdocParser.m \
                        ../../Sources/Parsers/GSHelpFormatDetector.m \
                        ../../Sources/Parsers/GSManParser.m \
                        ../../Sources/Parsers/GSTextParser.m \
                        ../../Sources/Rendering/GSHelpRenderer.m

# Markdown parser is compiled only once its header exists (same rule
# as the app GNUmakefile). CURDIR: gnustep-make does not guarantee the
# evaluation CWD for wildcard(). Must come after the assignment above
# or the += is lost.
ifneq ($(wildcard $(CURDIR)/../../Sources/Parsers/GSMarkdownParser.h),)
renderdump_OBJC_FILES += ../../Sources/Parsers/GSMarkdownParser.m
endif

renderdump_GUI_LIBS += $(CODEC_LIBS)

include $(GNUSTEP_MAKEFILES)/tool.make
