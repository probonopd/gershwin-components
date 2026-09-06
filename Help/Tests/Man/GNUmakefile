# Tests for GSManParser (M2-C): roff parsing and compressed pages.

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_Man_Roff t_Man_Compress

# Testing.h is not ARC-clean, so only the parser/core sources are
# compiled with ARC (per-file flags); the test TUs stay reference-counted.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ARCFLAGS = -fobjc-arc -fobjc-runtime=gnustep-2.0
# gnustep-make looks up $<_FILE_FLAGS, so the variable name must be
# the exact relative path used in *_OBJC_FILES.
../../Sources/Parsers/GSManParser.m_FILE_FLAGS = $(ARCFLAGS) $(CODEC_DEFINES)
../../Sources/Core/GSHelpNode.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpDocument.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpURL.m_FILE_FLAGS = $(ARCFLAGS)

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework \
                       -I../../Sources/Core \
                       -I../../Sources/Parsers

# Link only decompression libraries that compile AND link with a real
# symbol reference, and hand the parser the same GS_HAVE_* gates the
# app build uses; without them the readers are compiled out and the
# compressed-page fixtures would legitimately fail.
help_probe = printf 'int main(void){%s;return 0;}\n' '$(3)' | $(CC) -x c - -include $(1).h -o /dev/null -l$(2) 2>/dev/null && echo yes

CODEC_DEFINES =
DECOMP_LIBS =
ifneq ($(shell $(call help_probe,zlib,z,gzopen(0,0))),)
CODEC_DEFINES += -DGS_HAVE_ZLIB=1
DECOMP_LIBS += -lz
endif
ifneq ($(shell $(call help_probe,bzlib,bz2,BZ2_bzDecompressInit(0,0,0))),)
CODEC_DEFINES += -DGS_HAVE_BZ2=1
DECOMP_LIBS += -lbz2
endif
ifneq ($(shell $(call help_probe,lzma,lzma,lzma_code(0,0))),)
CODEC_DEFINES += -DGS_HAVE_LZMA=1
DECOMP_LIBS += -llzma
endif
ADDITIONAL_OBJCFLAGS += $(CODEC_DEFINES)

MAN_CORE_OBJS = ../../Sources/Core/GSHelpNode.m \
                ../../Sources/Core/GSHelpDocument.m \
                ../../Sources/Core/GSHelpURL.m

t_Man_Roff_OBJC_FILES = t_Man_Roff.m \
                        ../../Sources/Parsers/GSManParser.m \
                        $(MAN_CORE_OBJS)
t_Man_Roff_TOOL_LIBS += $(DECOMP_LIBS)

t_Man_Compress_OBJC_FILES = t_Man_Compress.m \
                            ../../Sources/Parsers/GSManParser.m \
                            $(MAN_CORE_OBJS)
t_Man_Compress_TOOL_LIBS += $(DECOMP_LIBS)

include $(GNUSTEP_MAKEFILES)/test-tool.make
