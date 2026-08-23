# Tests for the Help.app GSdoc parser (Phase 3)

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_GSdoc_Parser

# Testing.h is not ARC-clean, so only the parsed sources are compiled
# with ARC (per-file flags); the test TU stays reference-counted.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ARCFLAGS = -fobjc-arc -fobjc-runtime=gnustep-2.0
../../Sources/Parsers/GSGSDocParser.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpNode.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpDocument.m_FILE_FLAGS = $(ARCFLAGS)
ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework \
                      -I../../Sources/Parsers -I../../Sources/Core

t_GSdoc_Parser_OBJC_FILES = t_GSdoc_Parser.m \
                            ../../Sources/Parsers/GSGSDocParser.m \
                            ../../Sources/Core/GSHelpNode.m \
                            ../../Sources/Core/GSHelpDocument.m

include $(GNUSTEP_MAKEFILES)/test-tool.make
