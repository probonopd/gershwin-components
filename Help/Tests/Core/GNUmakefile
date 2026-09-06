# Tests for the Help.app core document model (M1)

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_Core_Document t_Core_Registry t_Core_URL t_Core_Catalog

# Testing.h is not ARC-clean, so only the Core sources are compiled
# with ARC (per-file flags); the test TUs stay reference-counted.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ARCFLAGS = -fobjc-arc -fobjc-runtime=gnustep-2.0
# gnustep-make looks up $<_FILE_FLAGS, so the variable name must be
# the exact relative path used in *_OBJC_FILES.
../../Sources/Core/GSHelpNode.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpDocument.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpParserRegistry.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpURL.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpAppScanner.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpManLocator.m_FILE_FLAGS = $(ARCFLAGS)
../../Sources/Core/GSHelpCatalog.m_FILE_FLAGS = $(ARCFLAGS)
ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework -I../../Sources/Core

t_Core_Document_OBJC_FILES = t_Core_Document.m \
                             ../../Sources/Core/GSHelpNode.m \
                             ../../Sources/Core/GSHelpDocument.m

t_Core_Registry_OBJC_FILES = t_Core_Registry.m \
                             ../../Sources/Core/GSHelpNode.m \
                             ../../Sources/Core/GSHelpDocument.m \
                             ../../Sources/Core/GSHelpParserRegistry.m

t_Core_URL_OBJC_FILES = t_Core_URL.m \
                        ../../Sources/Core/GSHelpURL.m

t_Core_Catalog_OBJC_FILES = t_Core_Catalog.m \
                            ../../Sources/Core/GSHelpNode.m \
                            ../../Sources/Core/GSHelpDocument.m \
                            ../../Sources/Core/GSHelpParserRegistry.m \
                            ../../Sources/Core/GSHelpURL.m \
                            ../../Sources/Core/GSHelpAppScanner.m \
                            ../../Sources/Core/GSHelpManLocator.m \
                            ../../Sources/Core/GSHelpCatalog.m

include $(GNUSTEP_MAKEFILES)/test-tool.make
