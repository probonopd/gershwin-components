# Tests for GSManParser (M2-C): roff parsing and compressed pages.

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_Man_Roff t_Man_Compress

# Testing.h is not ARC-clean, so only the parser/core sources are
# compiled with ARC (per-file flags); the test TUs stay reference-counted.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ARCFLAGS = -fobjc-arc -fobjc-runtime=gnustep-2.0
# gnustep-make looks up $<_FILE_FLAGS, so the variable name must be
# the exact relative path used in *_OBJC_FILES.
../../Sources/Parsers/GSManParser.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpNode.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpDocument.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpURL.m_FILE_FLAGS = $(ARCFLAGS)

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework \
                       -I../../Sources/Core \
                       -I../../Sources/Parsers

# Link only the decompression libraries whose headers exist; the parser
# source gates its readers on the same headers via __has_include.
DECOMP_LIBS =
ifeq ($(shell test -f /usr/include/zlib.h && echo yes),yes)
DECOMP_LIBS += -lz
endif
ifeq ($(shell test -f /usr/include/bzlib.h && echo yes),yes)
DECOMP_LIBS += -lbz2
endif
ifeq ($(shell test -f /usr/include/lzma.h && echo yes),yes)
DECOMP_LIBS += -llzma
endif

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
