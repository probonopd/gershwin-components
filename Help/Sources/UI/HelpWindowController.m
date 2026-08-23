/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "HelpWindowController.h"

#import "GSHelpRenderer.h"
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
#  if __has_include("GSGSDocParser.h")
#    import "GSGSDocParser.h"
#    define HELP_HAS_GSDOC 1
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

/* No Find menu item exists, so the content view swallows Cmd+F
 * itself and focuses the search field. */
@interface GSHelpContentView : NSView
@property (nonatomic, weak) NSSearchField *searchField;
@end

@implementation GSHelpContentView

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

@implementation HelpWindowController
{
    NSWindow *_window;
    NSButton *_backButton;
    NSButton *_forwardButton;
    NSSearchField *_searchField;
    NSOutlineView *_outline;
    NSTextView *_textView;
    /* Top-level sidebar groups: the open document's TOC plus the
     * scanned documentation catalog. */
    GSHelpTOCItem *_documentGroup;
    NSMutableArray<GSHelpTOCItem *> *_catalogGroups;
    GSHelpRenderer *_renderer;
    GSHelpHistory *_history;
    NSURL *_currentURL;
    GSHelpDocument *_currentDocument;
    BOOL _suppressSelection;
}

#pragma mark Window construction

- (void)showWindow
{
    if (_window == nil)
      {
        _history = [GSHelpHistory new];
        [self buildWindow];
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
    [_window setContentView: content];
    CGFloat height = frame.size.height;

    /* Toolbar row across the top. */
    NSRect toolbarFrame = NSMakeRect(0, height - kToolbarHeight,
                                     frame.size.width, kToolbarHeight);
    NSView *toolbar = [[NSView alloc] initWithFrame: toolbarFrame];
    toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview: toolbar];

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
    [toolbar addSubview: _backButton];
    [toolbar addSubview: _forwardButton];

    _searchField = [[NSSearchField alloc] initWithFrame:
        NSMakeRect(2 * kToolbarPad + 2 * kButtonWidth,
                   (kToolbarHeight - kFieldHeight) / 2.0,
                   frame.size.width - (3 * kToolbarPad + 2 * kButtonWidth),
                   kFieldHeight)];
    [[_searchField cell] setPlaceholderString: @"Search Documentation"];
    [_searchField setTarget: self];
    [_searchField setAction: @selector(searchAction:)];
    _searchField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [toolbar addSubview: _searchField];

    /* Sidebar with CONTENTS caption over the outline view. */
    NSRect sidebarFrame = NSMakeRect(0, 0, kSidebarWidth,
                                     height - kToolbarHeight);
    NSView *sidebar = [[NSView alloc] initWithFrame: sidebarFrame];
    sidebar.autoresizingMask = NSViewHeightSizable;
    [content addSubview: sidebar];

    NSTextField *caption = [[NSTextField alloc] initWithFrame:
        NSMakeRect(kToolbarPad, sidebarFrame.size.height - kSidebarCaptionHeight,
                   kSidebarWidth - 2 * kToolbarPad, 16)];
    [caption setStringValue: @"CONTENTS"];
    [caption setBezeled: NO];
    [caption setBordered: NO];
    [caption setEditable: NO];
    [caption setSelectable: NO];
    [caption setDrawsBackground: NO];
    [caption setFont: [NSFont boldSystemFontOfSize: 11]];
    caption.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [sidebar addSubview: caption];

    NSScrollView *sidebarScroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, 0, kSidebarWidth,
                   sidebarFrame.size.height - kSidebarCaptionHeight)];
    sidebarScroll.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable;
    [sidebarScroll setBorderType: NSBezelBorder];
    [sidebarScroll setHasVerticalScroller: YES];

    _outline = [[NSOutlineView alloc] initWithFrame:
        NSMakeRect(0, 0, kSidebarWidth, 100)];
    NSTableColumn *column = [[NSTableColumn alloc]
        initWithIdentifier: @"contents"];
    [[column headerCell] setStringValue: @"Contents"];
    [column setEditable: NO];
    [_outline addTableColumn: column];
    [_outline setOutlineTableColumn: column];
    [_outline setHeaderView: nil];
    [_outline setDataSource: self];
    [_outline setDelegate: self];
    [_outline setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
    [sidebarScroll setDocumentView: _outline];
    [sidebar addSubview: sidebarScroll];

    /* Document area fills the rest. */
    NSScrollView *documentScroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(kSidebarWidth + 1, 0,
                   frame.size.width - kSidebarWidth - 1,
                   height - kToolbarHeight)];
    documentScroll.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    [documentScroll setHasVerticalScroller: YES];
    [documentScroll setBorderType: NSNoBorder];

    /* The view builds and retains its own text network; a hand-built
     * storage would not be retained by the view under ARC and die
     * with the local reference. */
    _textView = [[NSTextView alloc] initWithFrame:
        NSMakeRect(0, 0, documentScroll.frame.size.width - 24, 100)];
    /* Editing stays off but selection/copy remain available (SPEC 48). */
    [_textView setEditable: NO];
    [_textView setSelectable: YES];
    [_textView setRichText: NO];
    [_textView setVerticallyResizable: YES];
    [_textView setHorizontallyResizable: NO];
    NSTextContainer *container = [_textView textContainer];
    [container setContainerSize:
        NSMakeSize(documentScroll.frame.size.width - 24, FLT_MAX)];
    [container setWidthTracksTextView: YES];
    [_textView setAutoresizingMask: NSViewWidthSizable];
    [_textView setTextContainerInset: NSMakeSize(12, 12)];
    [_textView setBackgroundColor: [NSColor windowBackgroundColor]];
    [_textView setDrawsBackground: YES];
    [_textView setDelegate: self];
    [_textView setLinkTextAttributes: @{
        NSForegroundColorAttributeName: [NSColor blueColor],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    }];
    [documentScroll setDocumentView: _textView];
    [content addSubview: documentScroll];

    /* Keyboard access basics: tab cycle through all controls. */
    [_backButton setNextKeyView: _forwardButton];
    [_forwardButton setNextKeyView: _searchField];
    [_searchField setNextKeyView: _outline];
    [_outline setNextKeyView: _textView];
    [_textView setNextKeyView: _backButton];
    [_window setInitialFirstResponder: _searchField];
    content.searchField = _searchField;
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
#ifdef HELP_HAS_MARKDOWN
        [registry registerParser: [GSMarkdownParser new]];
#endif
#ifdef HELP_HAS_MAN
        [registry registerParser: [GSManParser new]];
#endif
#ifdef HELP_HAS_GSDOC
        [registry registerParser: [GSGSDocParser new]];
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

    [self rebuildTOCItems: [document tableOfContents]];
    _suppressSelection = YES;
    [_outline reloadData];
    [self expandAllTOCItems];
    _suppressSelection = NO;
}

/* Wraps the open document's TOC under a "Contents" group so the
 * catalog groups sit alongside it in the same outline. */
- (void)rebuildTOCItems:(NSArray<GSHelpTOCEntry *> *)toc
{
    NSMutableArray<GSHelpTOCItem *> *children = [NSMutableArray new];
    NSMutableArray<GSHelpTOCItem *> *stack = [NSMutableArray new];

    for (GSHelpTOCEntry *entry in toc)
      {
        while ([stack count] > 0
                 && [[stack lastObject] entry].level >= entry.level)
          {
            [stack removeLastObject];
          }

        GSHelpTOCItem *item = [GSHelpTOCItem new];
        item.entry = entry;
        if ([stack count] > 0)
          {
            [[stack lastObject].children addObject: item];
          }
        else
          {
            [children addObject: item];
          }
        [stack addObject: item];
      }

    _documentGroup = [GSHelpTOCItem new];
    _documentGroup.title = @"Contents";
    _documentGroup.children = children;
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
- (NSArray *)topLevelItems
{
    NSMutableArray *items = [NSMutableArray new];
    if (_documentGroup != nil)
      {
        [items addObject: _documentGroup];
      }
    if (_catalogGroups != nil)
      {
        [items addObjectsFromArray: _catalogGroups];
      }
    return items;
}

/* The document TOC expands fully; catalog groups stay collapsed so
 * a 2600-page man section does not flood the outline. */
- (void)expandAllTOCItems
{
    for (GSHelpTOCItem *item in [self topLevelItems])
      {
        if (item == _documentGroup)
          {
            [self expandRecursively: item];
          }
        else
          {
            [_outline expandItem: item expandChildren: NO];
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
    /* Search index lands in M5. */
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
    /* Catalog leaf: open the document. */
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

#pragma mark Link clicks

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link
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
            [self displayURL: page push: YES];
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
