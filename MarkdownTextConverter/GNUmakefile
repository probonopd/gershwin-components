include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

PACKAGE_NAME = gershwin-components

BUNDLE_NAME = MarkdownConverter
BUNDLE_INSTALL_DIR = $(GNUSTEP_BUNDLES)/TextConverters

MarkdownConverter_OBJC_FILES = \
	MarkdownConsumer.m \
	MarkdownProducer.m \
	CodeTextBlock.m

MarkdownConverter_HEADER_FILES = \
	MarkdownConsumer.h \
	MarkdownProducer.h \
	CodeTextBlock.h

MarkdownConverter_PRINCIPAL_CLASS = MarkdownConsumer

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/bundle.make

-include GNUmakefile.postamble

