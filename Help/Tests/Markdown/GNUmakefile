# Tests for GSMarkdownParser (M2-B): block structure, inline styles,
# edge cases and malformed input.

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_Markdown_Blocks t_Markdown_Inline t_Markdown_Edge

# Testing.h is not ARC-clean, so only the parser/core sources are
# compiled with ARC (per-file flags); the test TUs stay reference-counted.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ARCFLAGS = -fobjc-arc -fobjc-runtime=gnustep-2.0
# gnustep-make looks up $<_FILE_FLAGS, so the variable name must be
# the exact relative path used in *_OBJC_FILES.
../../Sources/Parsers/GSMarkdownParser.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpNode.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpDocument.m_FILE_FLAGS = $(ARCFLAGS)

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework \
                       -I../../Sources/Core \
                       -I../../Sources/Parsers

MD_CORE_OBJS = ../../Sources/Core/GSHelpNode.m \
               ../../Sources/Core/GSHelpDocument.m

t_Markdown_Blocks_OBJC_FILES = t_Markdown_Blocks.m \
                               ../../Sources/Parsers/GSMarkdownParser.m \
                               $(MD_CORE_OBJS)

t_Markdown_Inline_OBJC_FILES = t_Markdown_Inline.m \
                               ../../Sources/Parsers/GSMarkdownParser.m \
                               $(MD_CORE_OBJS)

t_Markdown_Edge_OBJC_FILES = t_Markdown_Edge.m \
                             ../../Sources/Parsers/GSMarkdownParser.m \
                             $(MD_CORE_OBJS)

include $(GNUSTEP_MAKEFILES)/test-tool.make
