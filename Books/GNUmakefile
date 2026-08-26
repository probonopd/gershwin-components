include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = Books

Books_OBJC_FILES = \
	main.m \
	BooksAppDelegate.m \
	LibraryStore.m \
	LibraryBook.m \
	BookshelfController.m \
	BookshelfView.m \
	BookReaderController.m \
	BookPageView.m \
	GLPageTurnView.m \
	TOCPanelController.m \
	EPUBBook.m \
	EPUBTOCEntry.m \
	EPUBParser.m \
	EPUBPageRenderer.m \
	EPUBPaginator.m \
	EPUBHTMLConverter.m

Books_HEADER_FILES = \
	BooksAppDelegate.h \
	LibraryStore.h \
	LibraryBook.h \
	BookshelfController.h \
	BookshelfView.h \
	BookReaderController.h \
	BookPageView.h \
	GLPageTurnView.h \
	TOCPanelController.h \
	EPUBBook.h \
	EPUBTOCEntry.h \
	EPUBParser.h \
	EPUBPageRenderer.h \
	EPUBPaginator.h \
	EPUBHTMLConverter.h

Books_RESOURCE_FILES = \
	Books.png \
	wood.png \
	shelf.png \
	book-placeholder.png \
	BooksInfo.plist

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-runtime=gnustep-2.0 -Wno-protocol
ADDITIONAL_GUI_LIBS += -lGL

include $(GNUSTEP_MAKEFILES)/application.make
