include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = MarkdownReader
MarkdownReader_OBJC_FILES = main.m AppController.m \
    ../MarkdownTextConverter/MarkdownConsumer.m \
    ../MarkdownTextConverter/MarkdownProducer.m \
    ../MarkdownTextConverter/CodeTextBlock.m

MarkdownReader_HEADER_FILES = AppController.h

MarkdownReader_RESOURCE_FILES = Resources/Info-gnustep.plist

ADDITIONAL_INCLUDE_DIRS += -I../MarkdownTextConverter

include $(GNUSTEP_MAKEFILES)/application.make

