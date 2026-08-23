# Tests for GSGSdocParser: whitespace normalization (the reason this
# parser exists), structural mapping and API-entity rendering.

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_GSDoc_Whitespace t_GSDoc_Structure

ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ARCFLAGS = -fobjc-arc -fobjc-runtime=gnustep-2.0
../../Sources/Parsers/GSGSdocParser.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpNode.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpDocument.m_FILE_FLAGS = $(ARCFLAGS)

GSDOC_OBJS = ../../Sources/Parsers/GSGSdocParser.m \
             ../../Sources/Core/GSHelpNode.m \
             ../../Sources/Core/GSHelpDocument.m \
             ../../Sources/Parsers/GSHelpFormatDetector.m

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework \
                       -I../../Sources/Core \
                       -I../../Sources/Parsers

t_GSDoc_Whitespace_OBJC_FILES = t_GSDoc_Whitespace.m $(GSDOC_OBJS)
t_GSDoc_Structure_OBJC_FILES = t_GSDoc_Structure.m $(GSDOC_OBJS)

include $(GNUSTEP_MAKEFILES)/test-tool.make
