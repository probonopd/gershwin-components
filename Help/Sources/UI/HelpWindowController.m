/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "HelpWindowController.h"

#import "GSHelpRenderer.h"
#import "GSGSdocParser.h"
#import "GSHelpParserRegistry.h"
#import "GSHelpHistory.h"
#import "GSHelpManLocator.h"
#import "GSHelpURL.h"
#import "GSHelpCatalog.h"

/* Parsers land in a parallel work package; guard the imports so this
 * file compiles (and shows the welcome document) until they exist. */
#if defined(__has_include)
#  if __has_include("GSMarkdownParser.h")
#    import "GSMarkdownParser.h"
#    define HELP_HAS_MARKDOWN 1
#  endif
#  if __has_include("GSManParser.h")
#    import "GSManParser.h"
#    define HELP_HAS_MAN 1
#  endif
#  if __has_include("GSTextParser.h")
#    import "GSTextParser.h"
#    define HELP_HAS_TEXT 1
#  endif
#endif

/* Layout metrics per the Gershwin AppearanceMetrics house style:
 * 20px buttons, 22px text fields, 8/12px spacing multiples, sidebar
 * width from SPEC 36 (~220pt). */
static const CGFloat kToolbarHeight = 40.0;
static const CGFloat kButtonHeight = 20.0;
static const CGFloat kButtonWidth = 64.0;
static const CGFloat kFieldHeight = 22.0;
static const CGFloat kSidebarWidth = 220.0;
static const CGFloat kToolbarPad = 12.0;
static const CGFloat kSidebarCaptionHeight = 26.0;

#pragma mark - TOC tree item

/* One sidebar row: either a TOC entry of the open document (entry),
 * an openable leaf (url), or a plain group (children only). */
@interface GSHelpTOCItem : NSObject
@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) GSHelpTOCEntry *entry;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSMutableArray<GSHelpTOCItem *> *children;
@end

@implementation GSHelpTOCItem
- (instancetype)init
{
    self = [super init];
    if (self != nil)
      {
        _children = [NSMutableArray new];
      }
    return self;
}
@end

#pragma mark - Key equivalent view

@class HelpWindowController;

@interface HelpWindowController ()
- (void)relayoutForSize:(NSSize)size;
@end

/* No Find menu item exists, so the content view swallows Cmd+F
 * itself and focuses the search field. */
/* Root content view drives a full relayout on every size change:
 * the window manager may resize the window after buildWindow laid
 * the subviews out for the requested frame, and delta-based
 * autoresizing masks cannot recover from that initial mismatch. */
@interface GSHelpContentView : NSView
@property (nonatomic, weak) NSSearchField *searchField;
@property (nonatomic, weak) HelpWindowController *owner;
@end

@implementation GSHelpContentView

/* GNUstep's -setFrame: applies the rect directly without going
 * through -setFrameSize:, so both entry points must be hooked to
 * catch every resize path (window resize, superview resize, direct
 * setFrame:). Redundant calls are harmless - relayout is idempotent. */
- (void)setFrame:(NSRect)newFrame
{
    [super setFrame: newFrame];
    [_owner relayoutForSize: newFrame.size];
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize: newSize];
    [_owner relayoutForSize: newSize];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window] != nil && _owner != nil)
      {
        [_owner relayoutForSize: [self bounds].size];
      }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if (([event modifierFlags] & NSCommandKeyMask)
        && [[[event charactersIgnoringModifiers] lowercaseString]
               isEqualToString: @"f"]
        && _searchField != nil)
      {
        [_searchField.window makeFirstResponder: _searchField];
        return YES;
      }
    return [super performKeyEquivalent: event];
}

@end

#pragma mark - Window controller

/* GNUstep's delegate protocols do not mark methods optional, so
 * conforming would trigger -Wprotocol for every unimplemented stub;
 * the delegate assignments stay duck-typed instead. */
@interface HelpWindowController ()
@end

/* Sentinel URL for the pinned "Getting Started" sidebar entry. The
 * catalog emits this; we route it to the built-in welcome document. */
static NSString * const kGSHelpWelcomeURL = @"help://welcome";

@implementation HelpWindowController
{
    NSWindow *_window;
    GSHelpContentView *_content;
    NSView *_toolbar;
    NSButton *_backButton;
    NSButton *_forwardButton;
    NSSearchField *_searchField;
    NSView *_sidebar;
    NSTextField *_caption;
    NSScrollView *_sidebarScroll;
    NSScrollView *_documentScroll;
    NSOutlineView *_outline;
    NSTextView *_textView;
    /* Scanned documentation catalog. The open document is shown by
     * selecting and revealing its catalog leaf; its section list is NOT
     * mirrored into the sidebar (no "Contents" chapter). */
    NSMutableArray<GSHelpTOCItem *> *_catalogGroups;
    NSString *_activeFilter;
    NSArray<GSHelpTOCItem *> *_visibleTopLevel;
    GSHelpRenderer *_renderer;
    GSHelpHistory *_history;
    NSURL *_currentURL;
    GSHelpDocument *_currentDocument;
    BOOL _suppressSelection;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver: self];
}

#pragma mark Window construction

- (void)showWindow
{
    if (_window == nil)
      {
        _history = [GSHelpHistory new];
        [self buildWindow];
        _currentURL = [NSURL URLWithString: kGSHelpWelcomeURL];
        [self loadDocument: [self welcomeDocument]];
        [self loadCatalog];
      }
    [_window makeKeyAndOrderFront: self];
}

- (void)buildWindow
{
    NSRect frame = NSMakeRect(0, 0, 860, 560);
    NSUInteger styleMask = NSTitledWindowMask | NSClosableWindowMask
                           | NSMiniaturizableWindowMask | NSResizableWindowMask;

    _window = [[NSWindow alloc] initWithContentRect: frame
                                          styleMask: styleMask
                                            backing: NSBackingStoreBuffered
                                              defer: NO];
    [_window setTitle: @"Help"];
    [_window setMinSize: NSMakeSize(500, 300)];
    [_window center];

    GSHelpContentView *content =
        [[GSHelpContentView alloc] initWithFrame: frame];
    content.owner = self;
    [_window setContentView: content];
    _content = content;
    CGFloat height = frame.size.height;

    /* Toolbar row across the top. */
    _toolbar = [[NSView alloc] initWithFrame:
        NSMakeRect(0, height - kToolbarHeight, frame.size.width, kToolbarHeight)];
    [content addSubview: _toolbar];

    _backButton = [self toolbarButtonWithTitle: @"Back"];
    _forwardButton = [self toolbarButtonWithTitle: @"Forward"];
    [_backButton setTag: 1];
    [_forwardButton setTag: 2];
    /* Enabled/disabled by history state on every navigation. */
    [_backButton setEnabled: NO];
    [_forwardButton setEnabled: NO];
    [_backButton setFrame:
        NSMakeRect(kToolbarPad, (kToolbarHeight - kButtonHeight) / 2.0,
                   kButtonWidth, kButtonHeight)];
    [_forwardButton setFrame:
        NSMakeRect(NSMaxX([_backButton frame]) + 8.0,
                   (kToolbarHeight - kButtonHeight) / 2.0,
                   kButtonWidth, kButtonHeight)];
    [_toolbar addSubview: _backButton];
    [_toolbar addSubview: _forwardButton];

    _searchField = [[NSSearchField alloc] initWithFrame:
        NSMakeRect(2 * kToolbarPad + 2 * kButtonWidth,
                   (kToolbarHeight - kFieldHeight) / 2.0,
                   frame.size.width - (3 * kToolbarPad + 2 * kButtonWidth),
                   kFieldHeight)];
    [[_searchField cell] setPlaceholderString: @"Search Documentation"];
    [_searchField setTarget: self];
    [_searchField setAction: @selector(searchAction:)];
    [_toolbar addSubview: _searchField];

    /* Sidebar with CONTENTS caption over the outline view. */
    _sidebar = [[NSView alloc] initWithFrame:
        NSMakeRect(0, 0, kSidebarWidth, height - kToolbarHeight)];
    [content addSubview: _sidebar];

    _caption = [[NSTextField alloc] initWithFrame:
        NSMakeRect(kToolbarPad,
                   height - kToolbarHeight - kSidebarCaptionHeight,
                   kSidebarWidth - 2 * kToolbarPad, 16)];
    [_caption setStringValue: @"CONTENTS"];
    [_caption setBezeled: NO];
    [_caption setBordered: NO];
    [_caption setEditable: NO];
    [_caption setSelectable: NO];
    [_caption setDrawsBackground: NO];
    [_caption setFont: [NSFont boldSystemFontOfSize: 11]];
    [_sidebar addSubview: _caption];

    _sidebarScroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, 0, kSidebarWidth,
                   height - kToolbarHeight - kSidebarCaptionHeight)];
    [_sidebarScroll setBorderType: NSBezelBorder];
    [_sidebarScroll setHasVerticalScroller: YES];

    _outline = [[NSOutlineView alloc] initWithFrame:
        NSMakeRect(0, 0, kSidebarWidth, 100)];
    NSTableColumn *column = [[NSTableColumn alloc]
        initWithIdentifier: @"contents"];
    [[column headerCell] setStringValue: @"Help"];
    [column setEditable: NO];
    [_outline addTableColumn: column];
    [_outline setOutlineTableColumn: column];
    [_outline setHeaderView: nil];
    [_outline setDataSource: self];
    [_outline setDelegate: self];
    [_outline setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
    [_sidebarScroll setDocumentView: _outline];
    /* GNUstep does not auto-grow the table's last column when the scroll
     * view widens, leaving entry text clipped mid-scrollview; force the
     * column to track the visible width instead. */
    [_outline sizeLastColumnToFit];
    _sidebarScroll.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter]
        addObserver: self
           selector: @selector(sidebarFrameChanged:)
               name: NSViewFrameDidChangeNotification
             object: _sidebarScroll];
    [_sidebar addSubview: _sidebarScroll];

    /* Document area fills the rest. */
    _documentScroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(kSidebarWidth + 1, 0,
                   frame.size.width - kSidebarWidth - 1,
                   height - kToolbarHeight)];
    [_documentScroll setHasVerticalScroller: YES];
    [_documentScroll setBorderType: NSNoBorder];

    /* The view builds and retains its own text network; a hand-built
     * storage would not be retained by the view under ARC and die
     * with the local reference. */
    _textView = [[NSTextView alloc] initWithFrame:
        NSMakeRect(0, 0, _documentScroll.frame.size.width - 24, 100)];
    /* Editing stays off but selection/copy remain available (SPEC 48). */
    [_textView setEditable: NO];
    [_textView setSelectable: YES];
    [_textView setRichText: NO];
    [_textView setVerticallyResizable: YES];
    [_textView setHorizontallyResizable: NO];
    NSTextContainer *container = [_textView textContainer];
    [container setContainerSize:
        NSMakeSize(_documentScroll.frame.size.width - 24, FLT_MAX)];
    [container setWidthTracksTextView: YES];
    [_textView setAutoresizingMask: NSViewWidthSizable];
    [_textView setTextContainerInset: NSMakeSize(12, 12)];
    /* Reading pane is white so the document text reads like paper; code
     * blocks are shaded with the window background colour instead. */
    [_textView setBackgroundColor: [NSColor whiteColor]];
    [_textView setDrawsBackground: YES];
    [_textView setDelegate: self];
    [_textView setLinkTextAttributes: @{
        NSForegroundColorAttributeName: [NSColor blueColor],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    }];
    [_documentScroll setDocumentView: _textView];
    [content addSubview: _documentScroll];

    /* Keyboard access basics: tab cycle through all controls. */
    [_backButton setNextKeyView: _forwardButton];
    [_forwardButton setNextKeyView: _searchField];
    [_searchField setNextKeyView: _outline];
    [_outline setNextKeyView: _textView];
    [_textView setNextKeyView: _backButton];
    [_window setInitialFirstResponder: _searchField];
    content.searchField = _searchField;
}

/* Single source of truth for the pane layout, driven by the content
 * view on every size change (see GSHelpContentView above): frames are
 * recomputed from the real bounds, so a window manager that shows the
 * window at a different size than requested still lands consistent. */
- (void)relayoutForSize:(NSSize)size
{
    if (_toolbar == nil)
      {
        return;
      }

    CGFloat width = size.width;
    CGFloat height = size.height;

    [_toolbar setFrame:
        NSMakeRect(0, height - kToolbarHeight, width, kToolbarHeight)];
    [_backButton setFrame:
        NSMakeRect(kToolbarPad, (kToolbarHeight - kButtonHeight) / 2.0,
                   kButtonWidth, kButtonHeight)];
    [_forwardButton setFrame:
        NSMakeRect(NSMaxX([_backButton frame]) + 8.0,
                   (kToolbarHeight - kButtonHeight) / 2.0,
                   kButtonWidth, kButtonHeight)];
    [_searchField setFrame:
        NSMakeRect(2 * kToolbarPad + 2 * kButtonWidth,
                   (kToolbarHeight - kFieldHeight) / 2.0,
                   width - (3 * kToolbarPad + 2 * kButtonWidth),
                   kFieldHeight)];

    CGFloat bodyHeight = height - kToolbarHeight;
    [_sidebar setFrame: NSMakeRect(0, 0, kSidebarWidth, bodyHeight)];
    [_caption setFrame:
        NSMakeRect(kToolbarPad, bodyHeight - kSidebarCaptionHeight,
                   kSidebarWidth - 2 * kToolbarPad, 16)];
    [_sidebarScroll setFrame:
        NSMakeRect(0, 0, kSidebarWidth, bodyHeight - kSidebarCaptionHeight)];
    [_documentScroll setFrame:
        NSMakeRect(kSidebarWidth + 1, 0,
                   width - kSidebarWidth - 1, bodyHeight)];
}

- (NSButton *)toolbarButtonWithTitle:(NSString *)title
{
    NSButton *button = [[NSButton alloc] initWithFrame: NSZeroRect];
    [button setTitle: title];
    [button setBezelStyle: NSRoundedBezelStyle];
    [button setButtonType: NSMomentaryPushInButton];
    [button setImagePosition: NSNoImage];
    [button setTarget: self];
    [button setAction: @selector(navigationAction:)];
    return button;
}

#pragma mark Document loading

- (BOOL)openFileAtPath:(NSString *)path
{
    return [self displayURL: [NSURL fileURLWithPath: path] push: YES];
}

/* Central entry point for every navigation (SPEC 44): parses the
 * target, displays it, and optionally records a history entry. */
- (BOOL)displayURL:(NSURL *)url push:(BOOL)push
{
    /* The pinned "Getting Started" entry has no file of its own; route
     * it to the built-in welcome document instead of a real parser. */
    if ([[url absoluteString] isEqualToString: kGSHelpWelcomeURL])
      {
        if (push)
          {
            [_history pushURL: url];
          }
        _currentURL = url;
        [self loadDocument: [self welcomeDocument]];
        [self syncNavigationButtons];
        return YES;
      }

    id <GSHelpParser> parser = [[self registry] parserForURL: url];
    if (parser == nil)
      {
        NSLog(@"Help: no parser for %@", url);
        return NO;
      }

    NSError *error = nil;
    GSHelpDocument *document = [parser parseURL: url error: &error];
    if (document == nil)
      {
        NSLog(@"Help: failed to parse %@ (%@)", url, error);
        return NO;
      }

    if (_window == nil)
      {
        _history = [GSHelpHistory new];
        [self buildWindow];
      }
    if (push)
      {
        [_history pushURL: url];
      }
    _currentURL = url;
    [self loadDocument: document];
    [self syncNavigationButtons];
    return YES;
}

- (void)syncNavigationButtons
{
    [_backButton setEnabled: [_history canBack]];
    [_forwardButton setEnabled: [_history canForward]];
}

- (GSHelpParserRegistry *)registry
{
    /* AppKit drives all document loading on the main thread, so a
     * plain lazy init is sufficient here. */
    static GSHelpParserRegistry *registry = nil;
    if (registry == nil)
      {
        registry = [GSHelpParserRegistry new];
        /* gsdoc must register before the text fallback, which accepts
         * every URL (SPEC 51). */
        [registry registerParser: [GSGSdocParser new]];
#ifdef HELP_HAS_MARKDOWN
        [registry registerParser: [GSMarkdownParser new]];
#endif
#ifdef HELP_HAS_MAN
        [registry registerParser: [GSManParser new]];
#endif
#ifdef HELP_HAS_TEXT
        [registry registerParser: [GSTextParser new]];
#endif
      }
    return registry;
}

- (void)loadDocument:(GSHelpDocument *)document
{
    _renderer = [GSHelpRenderer new];
    _currentDocument = document;
    /* Remote images swap in after the initial layout; re-grow the view
     * when one arrives so the picture is not clipped. */
    __weak typeof(self) weakSelf = self;
    _renderer.imageDidLoad = ^{
        [weakSelf relayoutDocument];
    };
    NSAttributedString *rendered =
        [_renderer renderedStringForDocument: document];

    /* Explicit edit bracketing so the attached layout manager sees
     * the wholesale replacement. */
    [[_textView textStorage] beginEditing];
    [[_textView textStorage] setAttributedString: rendered];
    [[_textView textStorage] endEditing];
    /* Layout first, then grow the vertically resizable view to the
     * used rect; neither didChangeText nor sizeToFit relayouts a
     * wholesale-replaced storage reliably on GNUstep. */
    NSTextContainer *container = [_textView textContainer];
    [[_textView layoutManager] ensureLayoutForTextContainer: container];
    NSSize used = [[_textView layoutManager]
        usedRectForTextContainer: container].size;
    NSSize inset = [_textView textContainerInset];
    NSRect frame = [_textView frame];
    frame.size.height = used.height + 2 * inset.height;
    [_textView setFrame: frame];

    NSString *title = [document title];
    [_window setTitle: [title length] > 0 ? title : @"Help"];

    /* The sidebar stays a pure catalog tree; we do not mirror the open
     * document's section list into it. Selecting/revealing the matching
     * leaf happens in -expandAllTOCItems. */
    _suppressSelection = YES;
    [_outline reloadData];
    [self expandAllTOCItems];
    _suppressSelection = NO;
}

/* Re-measure the text after a late change (e.g. a remote image swapping
 * in) and grow the vertically resizable view so nothing is clipped. */
- (void)relayoutDocument
{
    if (_textView == nil)
      {
        return;
      }
    NSTextContainer *container = [_textView textContainer];
    NSLayoutManager *lm = [_textView layoutManager];
    [lm invalidateLayoutForCharacterRange:
           NSMakeRange(0, [[_textView textStorage] length])
                                 isSoft: NO
                    actualCharacterRange: NULL];
    [lm ensureLayoutForTextContainer: container];
    NSSize used = [lm usedRectForTextContainer: container].size;
    NSSize inset = [_textView textContainerInset];
    NSRect frame = [_textView frame];
    frame.size.height = used.height + 2 * inset.height;
    [_textView setFrame: frame];
    [_textView setNeedsDisplay: YES];
}

/* Recursively locates the catalog leaf (entry == nil, url set) whose
 * URL equals the given one; group rows carry no URL and are descended
 * into. Used to select/reveal the page we are currently showing. */
- (GSHelpTOCItem *)findLeafWithURL:(NSURL *)url
                        inChildren:(NSArray<GSHelpTOCItem *> *)children
{
    if (url == nil)
      {
        return nil;
      }
    BOOL isHelp = [[url scheme] isEqualToString: @"help"];
    NSString *matchPath = [url path];
    for (GSHelpTOCItem *item in children)
      {
        if ([item entry] == nil && [item url] != nil)
          {
            BOOL match = isHelp
                ? [[[item url] absoluteString]
                      isEqualToString: [url absoluteString]]
                : [[[item url] path] isEqualToString: matchPath];
            if (match)
              {
                return item;
              }
          }
        GSHelpTOCItem *found = [self findLeafWithURL: url
                                        inChildren: item.children];
        if (found != nil)
          {
            return found;
          }
      }
    return nil;
}

#pragma mark Catalog sidebar

/* The filesystem scan runs off the main thread (SPEC 74); the
 * outline reloads when the result arrives. */
- (void)loadCatalog
{
    [NSThread detachNewThreadSelector: @selector(scanCatalogThread)
                             toTarget: self
                           withObject: nil];
}

- (void)scanCatalogThread
{
    @autoreleasepool {
      NSArray *groups = [GSHelpCatalog systemCatalogItems];
      NSMutableArray *converted = [NSMutableArray new];
      for (GSHelpCatalogItem *group in groups)
        {
          [converted addObject: [self sidebarItemForCatalogItem: group]];
        }
      [self performSelectorOnMainThread:
                @selector(catalogDidScan:)
                          withObject: converted
                       waitUntilDone: NO];
    }
}

- (GSHelpTOCItem *)sidebarItemForCatalogItem:(GSHelpCatalogItem *)item
{
    GSHelpTOCItem *node = [GSHelpTOCItem new];
    node.title = [item title];
    node.url = [item url];
    node.children = [NSMutableArray new];
    for (GSHelpCatalogItem *child in [item children])
      {
        [node.children addObject: [self sidebarItemForCatalogItem: child]];
      }
    return node;
}

- (void)catalogDidScan:(NSArray<GSHelpTOCItem *> *)groups
{
    if (_catalogGroups == nil)
      {
        _catalogGroups = [NSMutableArray new];
      }
    [_catalogGroups removeAllObjects];
    [_catalogGroups addObjectsFromArray: groups];
    _suppressSelection = YES;
    [_outline reloadData];
    [self expandAllTOCItems];
    [_outline deselectAll: self];
    _suppressSelection = NO;
}

/* Top-level outline rows: open document first, then catalog. */
/* Serves the filtered tree while a search query is active. */
- (NSArray *)topLevelItems
{
    if (_activeFilter != nil)
      {
        if (_visibleTopLevel == nil)
          {
            NSMutableArray *items = [NSMutableArray new];
            for (GSHelpTOCItem *item in [self fullTopLevelItems])
              {
                GSHelpTOCItem *kept =
                    [self filteredItemForItem: item];
                if (kept != nil)
                  [items addObject: kept];
              }
            _visibleTopLevel = items;
          }
        return _visibleTopLevel;
      }
    return [self fullTopLevelItems];
}

/* The unfiltered sidebar root: the scanned catalog only. The open
 * document's headings live inside that tree on the leaf for the current
 * page, never as a separate floating section. */
- (NSArray *)fullTopLevelItems
{
    return _catalogGroups != nil ? _catalogGroups : @[];
}

/* Catalog groups open one level; the page we are currently showing is
 * revealed and selected in place (its ancestors expand) but we never
 * mirror its section list into the sidebar. */
- (void)expandAllTOCItems
{
    for (GSHelpTOCItem *item in [self topLevelItems])
      {
        [_outline expandItem: item expandChildren: NO];
      }
    GSHelpTOCItem *current =
        [self findLeafWithURL: _currentURL inChildren: _catalogGroups];
    if (current != nil)
      {
        NSMutableArray<GSHelpTOCItem *> *path = [NSMutableArray new];
        if ([self findItem: current
                 inChildren: [self fullTopLevelItems]
                       path: path])
          {
            for (GSHelpTOCItem *ancestor in path)
              {
                [_outline expandItem: ancestor];
              }
          }
        NSInteger row = [_outline rowForItem: current];
        if (row >= 0)
          {
            [_outline selectRowIndexes: [NSIndexSet indexSetWithIndex: row]
                           byExtendingSelection: NO];
            [_outline scrollRowToVisible: row];
          }
      }
}

- (void)expandRecursively:(GSHelpTOCItem *)item
{
    [_outline expandItem: item expandChildren: NO];
    for (GSHelpTOCItem *child in item.children)
      {
        [self expandRecursively: child];
      }
}

#pragma mark Welcome document

/* Built-in sample so the UI renders real content before any parser
 * exists; exercises every node kind the renderer supports. */
- (GSHelpDocument *)welcomeDocument
{
    GSHelpDocument *document = [GSHelpDocument new];
    document.title = @"Welcome";
    document.sourceType = @"built-in";

    GSHelpSection *root = [GSHelpSection new];
    root.title = @"Welcome";

    GSHelpHeading *h1 = [GSHelpHeading new];
    h1.text = @"Welcome to Help";
    h1.level = 1;
    [root appendNode: h1];

    GSHelpParagraph *intro = [GSHelpParagraph new];
    [intro appendNode: [self textRun: @"This viewer displays " style: GSHelpTextStylePlain]];
    [intro appendNode: [self textRun: @"Markdown" style: GSHelpTextStyleBold]];
    [intro appendNode: [self textRun: @", " style: GSHelpTextStylePlain]];
    [intro appendNode: [self textRun: @"man" style: GSHelpTextStyleItalic]];
    [intro appendNode: [self textRun: @" and GSdoc documentation in one native interface. Select any text to copy it." style: GSHelpTextStylePlain]];
    [root appendNode: intro];

    GSHelpAnchor *startAnchor = [GSHelpAnchor new];
    startAnchor.name = @"getting-started";
    [root appendNode: startAnchor];

    GSHelpHeading *h2 = [GSHelpHeading new];
    h2.text = @"Getting Started";
    h2.level = 2;
    [root appendNode: h2];

    GSHelpParagraph *openPara = [GSHelpParagraph new];
    [openPara appendNode: [self textRun: @"Open a document from the command line:" style: GSHelpTextStylePlain]];
    [root appendNode: openPara];

    GSHelpList *steps = [GSHelpList new];
    [steps appendNode: [self listItemWithTexts: @[@"Pass a file path to Help.app"]]];
    [steps appendNode: [self listItemWithTexts: @[@"Use the contents list on the left to jump between sections"]]];
    GSHelpListItem *nestedParent = [self listItemWithTexts: @[@"Supported sources"]];
    GSHelpList *nested = [GSHelpList new];
    nested.ordered = YES;
    [nested appendNode: [self listItemWithTexts: @[@"Markdown documents"]]];
    GSHelpListItem *manItem = [self listItemWithTexts: @[@"Unix man pages"]];
    [manItem appendNode: [self textRun: @" (monospace)" style: GSHelpTextStyleCode]];
    [nested appendNode: manItem];
    [nestedParent appendNode: nested];
    [steps appendNode: nestedParent];
    [root appendNode: steps];

    GSHelpHeading *h3 = [GSHelpHeading new];
    h3.text = @"Example Command";
    h3.level = 3;
    [root appendNode: h3];

    GSHelpCodeBlock *code = [GSHelpCodeBlock new];
    code.code = @"Help.app README.md\nHelp.app --man ls";
    code.language = @"shell";
    [root appendNode: code];

    GSHelpQuote *quote = [GSHelpQuote new];
    GSHelpParagraph *quotePara = [GSHelpParagraph new];
    [quotePara appendNode: [self textRun: @"Documentation is displayed natively - no web engine involved." style: GSHelpTextStylePlain]];
    [quote appendNode: quotePara];
    [root appendNode: quote];

    GSHelpParagraph *linkPara = [GSHelpParagraph new];
    GSHelpLink *link = [GSHelpLink new];
    link.target = @"help://app/welcome/getting-started";
    [link appendLabelRun: @"Getting started section" style: GSHelpTextStylePlain];
    [linkPara appendNode: link];
    [linkPara appendNode: [self textRun: @" links resolve inside the documentation." style: GSHelpTextStylePlain]];
    [root appendNode: linkPara];

    GSHelpHeading *h4 = [GSHelpHeading new];
    h4.text = @"Format Overview";
    h4.level = 4;
    [root appendNode: h4];

    GSHelpTable *table = [GSHelpTable new];
    GSHelpTableRow *header = [GSHelpTableRow new];
    [header appendCellWithText: @"Format"];
    [header appendCellWithText: @"Used for"];
    [table appendNode: header];
    GSHelpTableRow *row1 = [GSHelpTableRow new];
    [row1 appendCellWithText: @"Markdown"];
    [row1 appendCellWithText: @"Application guides"];
    [table appendNode: row1];
    GSHelpTableRow *row2 = [GSHelpTableRow new];
    [row2 appendCellWithText: @"man"];
    [row2 appendCellWithText: @"Command line tools"];
    [table appendNode: row2];
    [root appendNode: table];

    document.rootNode = root;
    return document;
}

- (GSHelpText *)textRun:(NSString *)string style:(GSHelpTextStyle)style
{
    GSHelpText *run = [GSHelpText new];
    run.string = string;
    run.style = style;
    return run;
}

- (GSHelpListItem *)listItemWithTexts:(NSArray *)specs
{
    /* Specs alternate string, optional style. Keeps the fixture terse. */
    GSHelpListItem *item = [GSHelpListItem new];
    NSUInteger i = 0;
    while (i < [specs count])
      {
        GSHelpTextStyle style = GSHelpTextStylePlain;
        if (i + 1 < [specs count] && [specs[i + 1] isKindOfClass: [NSNumber class]])
          {
            style = [specs[i + 1] unsignedIntegerValue];
            i += 1;
          }
        [item appendNode: [self textRun: specs[i] style: style]];
        i += 1;
      }
    return item;
}

#pragma mark Actions

- (IBAction)navigationAction:(id)sender
{
    NSURL *target = nil;
    if ([sender tag] == 1)
      {
        target = [_history goBack];
      }
    else if ([sender tag] == 2)
      {
        target = [_history goForward];
      }
    /* Re-entry without pushing: the position in history already
     * records where we are going. */
    if (target != nil)
      {
        [self displayURL: target push: NO];
      }
}

- (IBAction)searchAction:(id)sender
{
    /* Filter the sidebar in place: an item stays visible when its own
     * title matches or any descendant matches (so matching leaves keep
     * their group hierarchy).  An empty query restores the full tree. */
    NSString *query = [_searchField stringValue];
    _activeFilter = query.length > 0 ? [query copy] : nil;
    _visibleTopLevel = nil;

    [_outline reloadData];
    for (GSHelpTOCItem *item in [self topLevelItems])
      {
        [_outline expandItem: item expandChildren: YES];
      }
}

/* Deep-copies `item` keeping only children whose title matches the active
 * filter or that contain such a child. Returns nil when the whole subtree
 * filters out. Group nodes survive purely on their children. */
- (nullable GSHelpTOCItem *)filteredItemForItem:(GSHelpTOCItem *)item
{
    BOOL selfMatches = _activeFilter == nil ||
        ([item title] != nil &&
         [[item title] rangeOfString: _activeFilter
                             options: NSCaseInsensitiveSearch]
             .location != NSNotFound);
    GSHelpTOCItem *copy = [GSHelpTOCItem new];
    copy.title = [item title];
    copy.entry = item.entry;
    /* Leaves opened by URL (not catalog entries) carry their target here;
     * dropping it made filtered-tree clicks silently load nothing. */
    copy.url = item.url;
    for (GSHelpTOCItem *child in item.children)
      {
        GSHelpTOCItem *kept = [self filteredItemForItem: child];
        if (kept != nil)
          {
            [copy.children addObject: kept];
          }
        else if (selfMatches)
          {
            /* Leaf itself matched: keep its original subtree verbatim. */
            [copy.children addObject: child];
          }
      }
    if (copy.children.count > 0)
      return copy;
    return selfMatches ? copy : nil;
}

- (void)sidebarFrameChanged:(NSNotification *)notification
{
    (void)notification;
    /* Keep the single column as wide as the visible clip area so entry
     * titles are never truncated mid-scrollview. */
    [_outline sizeLastColumnToFit];
}

#pragma mark NSOutlineView data source

- (NSUInteger)outlineView:(NSOutlineView *)outlineView
   numberOfChildrenOfItem:(nullable id)item
{
    if (item == nil)
      {
        return [[self topLevelItems] count];
      }
    return [((GSHelpTOCItem *)item).children count];
}

- (id)outlineView:(NSOutlineView *)outlineView
            child:(NSInteger)index
           ofItem:(nullable id)item
{
    NSArray *children = (item == nil)
        ? [self topLevelItems] : ((GSHelpTOCItem *)item).children;
    return children[index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
   isItemExpandable:(nullable id)item
{
    return [((GSHelpTOCItem *)item).children count] > 0;
}

- (id)outlineView:(NSOutlineView *)outlineView
    objectValueForTableColumn:(nullable NSTableColumn *)tableColumn
                       byItem:(nullable id)item
{
    GSHelpTOCItem *node = (GSHelpTOCItem *)item;
    if ([node title] != nil)
      {
        return [node title];
      }
    return node.entry.heading.text;
}

#pragma mark Sidebar selection

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
    NSInteger row = [_outline selectedRow];
    if (row < 0 || _textView == nil || _suppressSelection)
      {
        return;
      }

    GSHelpTOCItem *item = [_outline itemAtRow: row];
    if (item == nil)
      {
        return;
      }

    /* Catalog leaf: open the document. The load rebuilds the outline
     * and clears the selection, so re-reveal and re-select the item
     * afterwards so it stays chosen and on screen. */
    if ([item entry] == nil && [item url] != nil)
      {
        NSString *path = [[item url] path];
        if (path != nil)
          {
            [self openFileAtPath: path];
          }
        else
          {
            [self displayURL: [item url] push: YES];
          }
        [self revealAndSelectItem: item];
        return;
      }
    if ([item entry] == nil)
      {
        return;
      }

    NSRange range = [_renderer rangeOfHeadingText:
                             item.entry.heading.text];
    if (range.location != NSNotFound)
      {
        [_textView scrollRangeToVisible: range];
      }
}

/* Re-establishes selection on an item displaced by an outline reload
 * (e.g. after opening a catalog document): expands its ancestor path
 * so it is visible, then selects and scrolls it into view. */
- (void)revealAndSelectItem:(GSHelpTOCItem *)item
{
    if (item == nil)
      {
        return;
      }
    NSMutableArray<GSHelpTOCItem *> *path = [NSMutableArray new];
    if (![self findItem: item
             inChildren: [self fullTopLevelItems]
                   path: path])
      {
        return;
      }
    for (GSHelpTOCItem *ancestor in path)
      {
        [_outline expandItem: ancestor];
      }
    NSInteger row = [_outline rowForItem: item];
    if (row >= 0)
      {
        _suppressSelection = YES;
        [_outline selectRowIndexes:
            [NSIndexSet indexSetWithIndex: row]
                       byExtendingSelection: NO];
        _suppressSelection = NO;
        [_outline scrollRowToVisible: row];
      }
}

- (BOOL)findItem:(GSHelpTOCItem *)target
        inChildren:(NSArray<GSHelpTOCItem *> *)children
              path:(NSMutableArray<GSHelpTOCItem *> *)path
{
    for (GSHelpTOCItem *child in children)
      {
        if (child == target)
          {
            [path addObject: child];
            return YES;
          }
        if ([self findItem: target inChildren: child.children path: path])
          {
            [path insertObject: child atIndex: 0];
            return YES;
          }
      }
    return NO;
}

/* Maps a help://man link to the sidebar leaf whose file URL matches the
 * page located for that command+section, so a click can reveal and
 * select it. Returns nil when the catalog has not been scanned yet or
 * the page is not listed. */
- (nullable GSHelpTOCItem *)catalogItemForManURL:(NSURL *)url
                                         pageURL:(NSURL *)page
{
    if (page == nil || _catalogGroups == nil)
      {
        return nil;
      }
    NSString *standardized = [[page URLByStandardizingPath] path];
    if (standardized == nil)
      {
        return nil;
      }
    return [self findCatalogItemWithPath: standardized
                              inChildren: _catalogGroups];
}

- (nullable GSHelpTOCItem *)findCatalogItemWithPath:(NSString *)path
                                        inChildren:
                                            (NSArray<GSHelpTOCItem *> *)children
{
    for (GSHelpTOCItem *item in children)
      {
        NSURL *itemURL = item.url;
        if (itemURL != nil)
          {
            NSString *itemPath = [[itemURL URLByStandardizingPath] path];
            if (itemPath != nil && [itemPath isEqualToString: path])
              {
                return item;
              }
          }
        GSHelpTOCItem *found = [self findCatalogItemWithPath: path
                                                  inChildren: item.children];
        if (found != nil)
          {
            return found;
          }
      }
    return nil;
}

#pragma mark Link clicks

/* GNUstep's NSTextView only dispatches the atIndex: variant of this
 * delegate method, so both selectors are implemented and forwarded to
 * the shared handler. */
- (BOOL)textView:(NSTextView *)textView
    clickedOnLink:(id)link
         atIndex:(NSUInteger)charIndex
{
    return [self handleLinkClick: link];
}

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link
{
    return [self handleLinkClick: link];
}

- (BOOL)handleLinkClick:(id)link
{
    NSString *target;
    if ([link isKindOfClass: [NSURL class]])
      {
        target = [(NSURL *)link absoluteString];
      }
    else if ([link isKindOfClass: [NSString class]])
      {
        target = link;
      }
    else
      {
        return NO;
      }

    /* In-document anchor: scroll, no history entry. */
    if ([target hasPrefix: @"#"])
      {
        [self scrollToAnchor:
                  [target substringFromIndex: 1]];
        return YES;
      }

    NSURL *url = nil;
    if ([GSHelpURL isHelpURL:
                        [NSURL URLWithString: target]]
        || [target hasPrefix: @"help://"])
      {
        url = [NSURL URLWithString: target];
      }
    else
      {
        url = [NSURL URLWithString: target
                     relativeToURL: _currentURL];
      }
    if (url == nil)
      {
        return NO;
      }
    /* Relative targets (e.g. a sibling "bar.md") must be resolved
     * against the current document before navigation; otherwise the
     * parser registry sees a scheme-less URL and finds no parser. */
    url = [url absoluteURL];
    if ([[url scheme] isEqualToString: @"file"])
      {
        url = [url URLByStandardizingPath];
      }
    return [self resolveInternalURL: url];
}

/* help:// URLs dispatch by kind; everything else goes through the
 * parser registry. Unknown help targets show a placeholder instead
 * of failing silently. */
- (BOOL)resolveInternalURL:(NSURL *)url
{
    if (![self targetIsFile: url])
      {
        NSString *kind = [GSHelpURL kindOfURL: url];
        if ([kind isEqualToString: @"man"])
          {
            NSURL *page = [GSHelpManLocator
                locateManPageWithCommand: [GSHelpURL commandOfURL: url]
                                 section: [GSHelpURL sectionOfURL: url]
                             searchPaths:
                                 [GSHelpManLocator defaultSearchPaths]];
            if (page == nil)
              {
                [self showPlaceholderForURL: url];
                return YES;
              }
            /* Prefer selecting the page in the sidebar (when it is part
             * of the catalog): that reuses the catalog-click path which
             * both shows the document and keeps the row selected. Fall
             * back to a plain open when it is not in the catalog. */
            GSHelpTOCItem *item = [self catalogItemForManURL: url
                                                    pageURL: page];
            if (item != nil)
              {
                [self displayURL: page push: YES];
                [self revealAndSelectItem: item];
              }
            else
              {
                [self displayURL: page push: YES];
              }
            return YES;
          }
        [self showPlaceholderForURL: url];
        return YES;
      }
    return [self displayURL: url push: YES];
}

- (BOOL)targetIsFile:(NSURL *)url
{
    return [[url scheme] length] == 0
        || [[url scheme] isEqualToString: @"file"];
}

- (void)showPlaceholderForURL:(NSURL *)url
{
    GSHelpDocument *document = [GSHelpDocument new];
    document.title = @"Not available";
    document.sourceType = @"built-in";
    GSHelpSection *root = [GSHelpSection new];
    GSHelpHeading *h = [GSHelpHeading new];
    h.text = @"Documentation not available";
    h.level = 1;
    [root appendNode: h];
    GSHelpParagraph *p = [GSHelpParagraph new];
    [p appendNode: [self textRun:
          [NSString stringWithFormat:
                       @"No documentation is registered for %@.",
                       url]
                      style: GSHelpTextStylePlain]];
    [root appendNode: p];
    document.rootNode = root;
    [self loadDocument: document];
    [self syncNavigationButtons];
}

- (void)scrollToAnchor:(NSString *)name
{
    if (_currentDocument == nil)
      {
        return;
      }
    /* Anchors sit directly before their heading; scroll to that
     * heading's rendered range. */
    GSHelpNode *node = [[_currentDocument anchors] objectForKey: name];
    if (node == nil || [node parent] == nil)
      {
        return;
      }
    NSArray *siblings = [[node parent] children];
    NSUInteger index = [siblings indexOfObject: node];
    for (NSUInteger i = index + 1; i < [siblings count]; i++)
      {
        GSHelpNode *next = siblings[i];
        if ([next isKindOfClass: [GSHelpHeading class]])
          {
            NSRange range = [_renderer rangeOfHeadingText:
                                       ((GSHelpHeading *)next).text];
            if (range.location != NSNotFound)
              {
                [_textView scrollRangeToVisible: range];
              }
            return;
          }
      }
}

@end
