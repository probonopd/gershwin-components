# Tests for the plain-text fallback parser and format detection (M2 D)

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_Text_Parser t_Text_Detector

# Testing.h is not ARC-clean, so only the source files are compiled
# with ARC (per-file flags); the test TUs stay reference-counted.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ARCFLAGS = -fobjc-arc -fobjc-runtime=gnustep-2.0
../../Sources/Core/GSHelpNode.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpDocument.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Parsers/GSTextParser.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Parsers/GSHelpFormatDetector.m_FILE_FLAGS = $(ARCFLAGS)

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework \
                      -I../../Sources/Core -I../../Sources/Parsers

t_Text_Parser_OBJC_FILES = t_Text_Parser.m \
                           ../../Sources/Core/GSHelpNode.m \
                           ../../Sources/Core/GSHelpDocument.m \
                           ../../Sources/Parsers/GSTextParser.m

t_Text_Detector_OBJC_FILES = t_Text_Detector.m \
                             ../../Sources/Parsers/GSHelpFormatDetector.m

include $(GNUSTEP_MAKEFILES)/test-tool.make
