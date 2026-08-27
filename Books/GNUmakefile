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
	EPUBHTMLConverter.m \
	EPUBPageLocator.m \
	EPUBAnnotation.m \
	AnnotationStore.m

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
	EPUBHTMLConverter.h \
	EPUBPageLocator.h \
	EPUBAnnotation.h \
	AnnotationStore.h

Books_RESOURCE_FILES = \
	Books.png \
	wood.png \
	shelf.png \
	book-placeholder.png \
	BooksInfo.plist

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-runtime=gnustep-2.0 -Wno-protocol
ADDITIONAL_GUI_LIBS += -lGL

# Register Books as the handler for .epub so double-click opens the app.
# Run as the real (desktop) user, not root: make_services writes the
# association cache into that user's ~/Library/Services, which is what the
# running Workspace actually reads.
after-install::
	-@u="$$SUDO_USER"; [ -z "$$u" ] && u=`whoami`; \
	  if [ "$$u" != "root" ]; then \
	    su "$$u" -c "/Local/Library/Tools/make_services" 2>/dev/null || true; \
	  else \
	    /Local/Library/Tools/make_services 2>/dev/null || true; \
	  fi

include $(GNUSTEP_MAKEFILES)/application.make
