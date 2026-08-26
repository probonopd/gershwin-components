include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TEST_TOOL_NAME = test-epub

test-epub_OBJC_FILES = \
	test-epub.m \
	../EPUBBook.m \
	../EPUBTOCEntry.m \
	../EPUBParser.m \
	../EPUBPageRenderer.m \
	../EPUBPaginator.m \
	../EPUBHTMLConverter.m

test-epub_HEADER_FILES = \
	../EPUBBook.h \
	../EPUBTOCEntry.h \
	../EPUBParser.h \
	../EPUBPageRenderer.h \
	../EPUBPaginator.h \
	../EPUBHTMLConverter.h

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-runtime=gnustep-2.0 -Wno-protocol -I..
ADDITIONAL_LDFLAGS += -lgnustep-gui -lGL

include $(GNUSTEP_MAKEFILES)/test-tool.make
