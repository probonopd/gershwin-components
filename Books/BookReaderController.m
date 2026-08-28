/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "BookReaderController.h"
#import "LibraryBook.h"
#import "LibraryStore.h"
#import "EPUBBook.h"
#import "EPUBTOCEntry.h"
#import "EPUBPageRenderer.h"
#import "EPUBHTMLConverter.h"
#import "EPUBPageLocator.h"
#import "BookPageView.h"
#import "TOCPanelController.h"
#import "EPUBAnnotation.h"
#import "AnnotationStore.h"

// The annotations list forwards Backspace / Forward-Delete on the selected row
// to a delete action, so the row can be removed from the keyboard without a
// dedicated button.
@interface BooksAnnoTableView : NSTableView
@property (nonatomic, copy) void (^deleteBlock)(void);
@end

@implementation BooksAnnoTableView
- (void)keyDown:(NSEvent *)event
{
  NSString *s = [event charactersIgnoringModifiers];
  if ([s length] > 0)
    {
      unichar c = [s characterAtIndex:0];
      if (c == NSDeleteCharacter || c == NSDeleteFunctionKey || c == 0x08)
        {
          if (_deleteBlock != nil) _deleteBlock();
          return;
        }
    }
  [super keyDown:event];
}
@end

@interface BookReaderController () <BookPageViewDelegate, NSWindowDelegate, TOCPanelDelegate,
                                       NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) LibraryBook *libBook;
@property (nonatomic, strong) EPUBBook *epub;
@property (nonatomic, strong) NSMutableAttributedString *fullText;
@property (nonatomic, strong) NSAttributedString *baseText;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *docStart;
@property (nonatomic, strong) BookPageView *pageView;
@property (nonatomic, strong) TOCPanelController *tocPanel;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) NSInteger theme;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, strong) NSColor *textColor;
@property (nonatomic, assign) NSUInteger currentSpread;
@property (nonatomic, strong) NSButton *themeButton;
@property (nonatomic, assign) NSInteger pageNumberMode;
@property (nonatomic, strong) EPUBPageLocator *locator;
@property (nonatomic, strong) NSMutableArray<NSString *> *pageLabels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *docAnchors;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *docRelPaths;
@property (nonatomic, strong) AnnotationStore *annoStore;
@property (nonatomic, strong) NSMutableArray<EPUBAnnotation *> *annotations;
@property (nonatomic, copy) NSString *highlightColorLabel;
@property (nonatomic, strong) NSButton *pencilButton;
@property (nonatomic, strong) NSDrawer *annoDrawer;
@property (nonatomic, strong) BooksAnnoTableView *annoTable;
@property (nonatomic, strong) NSTextField *annoStatus;
@property (nonatomic, strong) NSTextView *annoNote;
@property (nonatomic, assign) BOOL annoNotePlaceholderActive;
@property (nonatomic, strong) EPUBAnnotation *selectedAnno;
@property (nonatomic, strong) NSArray<EPUBPageListEntry *> *authoredEntries;
@property (nonatomic, strong) NSButton *pagesButton;
@property (nonatomic, assign) CGFloat lineSpacing;
@property (nonatomic, assign) CGFloat pageMargin;
@property (nonatomic, copy) NSString *fontFamily;
@property (nonatomic, strong) NSSlider *scrubber;
@property (nonatomic, strong) NSTextField *pageField;
@property (nonatomic, strong) NSButton *lineDownBtn;
@property (nonatomic, strong) NSButton *lineUpBtn;
@property (nonatomic, strong) NSButton *marginDownBtn;
@property (nonatomic, strong) NSButton *marginUpBtn;
@property (nonatomic, strong) NSPopUpButton *fontPopup;
@property (nonatomic, strong) NSTimer *resizeTimer;
// GNUstep may not post windowDidResize (or may keep a stale -[win frame]) when
// the window manager resizes the window, so we also poll the real size and
// relayout when it actually changes.
@property (nonatomic, strong) NSTimer *sizePollTimer;
@property (nonatomic, assign) NSSize lastContentSize;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSDrawer *searchDrawer;
@property (nonatomic, strong) NSTableView *searchTable;
@property (nonatomic, strong) NSTextField *searchStatus;
@property (nonatomic, copy) NSArray<NSValue *> *searchMatches;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *history;
@property (nonatomic, assign) NSInteger histPos;
@property (nonatomic, strong) NSButton *backButton;
@property (nonatomic, strong) NSButton *forwardButton;
// Ordered groups of toolbar controls; each group is laid out touching (so the
// theme renders it as one control) and separated from the next by a constant gap.
@property (nonatomic, strong) NSArray<NSArray<NSView *> *> *toolbarGroups;
@end

@implementation BookReaderController

- (instancetype)initWithLibraryBook:(LibraryBook *)book
{
  self = [super initWithWindow:nil];
  if (self)
    {
      _libBook = book;
      _fontSize = book.fontSize > 0 ? book.fontSize : 14.0;
      _theme = book.theme;
      _currentSpread = book.lastSpreadIndex;
      _lineSpacing = book.lineSpacing;
      _pageMargin = book.pageMargin;
      _fontFamily = [book.fontFamily copy];
      _docStart = [NSMutableDictionary dictionary];
      [self updateThemeColors];
      if (![self parseBook])
        return nil;
      [self buildWindow];
    }
  return self;
}

- (BOOL)parseBook
{
  NSError *err = nil;
  _epub = [[EPUBBook alloc] initWithEPUBAtPath:_libBook.epubPath error:&err];
  if (_epub == nil)
    {
      NSAlert *a = [NSAlert alertWithMessageText:@"Could not open book"
                                   defaultButton:@"OK"
                                 alternateButton:nil
                                     otherButton:nil
                       informativeTextWithFormat:
                         @"%@", [err localizedDescription] ?: _libBook.epubPath];
      [a runModal];
      return NO;
    }

  NSMutableAttributedString *base = [[NSMutableAttributedString alloc] init];
  NSUInteger offset = 0;
  _docAnchors = [NSMutableDictionary dictionary];
  _docRelPaths = [NSMutableDictionary dictionary];
  for (NSString *docAbs in _epub.spine)
    {
      NSData *data = [NSData dataWithContentsOfFile:docAbs];
      if (data == nil) continue;
      // Remember each spine document's path relative to the EPUB root so
      // annotations can carry a standard `source` for that resource.
      NSString *rel = [docAbs stringByReplacingOccurrencesOfString:_epub.extractedRoot
                                                         withString:@""];
      if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
      [_docRelPaths setObject:rel forKey:[docAbs lastPathComponent]];
      NSURL *baseURL = [NSURL fileURLWithPath:[docAbs stringByDeletingLastPathComponent]];
      NSDictionary<NSString *, NSNumber *> *anchors = nil;
      NSAttributedString *part = [EPUBHTMLConverter
          attributedStringFromXHTMLAtPath:docAbs
                                    baseURL:baseURL
                             containerRoot:_epub.extractedRoot
                                   anchors:&anchors
                                     error:NULL];
      if ([part length] > 0)
        {
          [_docStart setObject:@(offset) forKey:[docAbs lastPathComponent]];
          if (anchors != nil)
            [_docAnchors setObject:anchors forKey:[docAbs lastPathComponent]];
          [base appendAttributedString:part];
          // Force each chapter (spine document) to begin on a new page.
          [base addAttribute:EPUBPageBreakAttributeName
                       value:@YES
                       range:NSMakeRange(offset, 1)];
          offset += [part length];
        }
    }
  if ([base length] == 0)
    {
      [_epub cleanupExtraction];
      return NO;
    }
  // Keep the converter output untouched as the scaling source; _fullText is the
  // working copy whose fonts are re-derived from _baseText on every zoom change.
  _baseText = [base copy];
  _fullText = [base mutableCopy];
  [self applyFont];
  [self applyTextColor];
  [self applyLineSpacing];

  // EPUB Locators: resolve any authored page-list to character offsets and
  // build the locator that maps a position to the page number shown in footers.
  _pageNumberMode = _libBook.pageNumberMode;
  [self buildAuthoredEntries];
  _locator = [[EPUBPageLocator alloc] initWithFullText:_fullText];
  [_locator setAuthoredEntries:_authoredEntries];

  // Load any saved annotations for this book and resolve their document-relative
  // offsets back to absolute reading-text offsets using the spine map.
  _highlightColorLabel = [EPUBAnnotation defaultColorLabel];
  _annoStore = [[AnnotationStore alloc] initWithBook:_libBook];
  _annotations = [[_annoStore load] mutableCopy];
  if (_annotations == nil) _annotations = [NSMutableArray array];
  [self mapLoadedAnnotations];
  return YES;
}

// Map the EPUB's authored page-list (href + label) to character offsets in the
// concatenated reading text. Each href resolves to a spine document; a #fragment
// resolves via that document's parsed element-id anchors. Entries we cannot
// place (missing document or unresolved fragment) are dropped, exactly as a
// reading system is permitted to do with a malformed page-list.
- (void)buildAuthoredEntries
{
  NSMutableArray<EPUBPageListEntry *> *entries = [NSMutableArray array];
  for (NSDictionary<NSString *, NSString *> *pl in _epub.pageList)
    {
      NSString *href = pl[@"href"];
      NSString *label = pl[@"label"];
      if ([href length] == 0 || [label length] == 0)
        continue;
      NSString *frag = nil;
      NSRange hash = [href rangeOfString:@"#"];
      NSString *docRel;
      if (hash.location != NSNotFound)
        {
          docRel = [href substringToIndex:hash.location];
          frag = [href substringFromIndex:hash.location + 1];
        }
      else
        {
          docRel = href;
        }
      NSString *abs = [_epub absolutePathForContent:docRel];
      if (abs == nil)
        continue;
      NSNumber *baseOff = [_docStart objectForKey:[abs lastPathComponent]];
      if (baseOff == nil)
        continue;
      NSUInteger off = [baseOff unsignedIntegerValue];
      if ([frag length] > 0)
        {
          NSDictionary<NSString *, NSNumber *> *am = [_docAnchors objectForKey:[abs lastPathComponent]];
          NSNumber *ao = (am != nil) ? am[frag] : nil;
          if (ao == nil)
            continue;
          off += [ao unsignedIntegerValue];
        }
      [entries addObject:[EPUBPageListEntry entryWithOffset:off label:label]];
    }
  _authoredEntries = entries;
}

// Compute the footer label for every paginated visual page from its start
// offset. Stored in page order so BookPageView can overlay them by index.
- (void)buildPageLabels
{
  if (_pageView == nil || [_pageView pageCount] == 0)
    return;
  NSUInteger pc = [_pageView pageCount];
  NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:pc];
  for (NSUInteger i = 0; i < pc; i++)
    {
      NSRange r = [_pageView rangeForPage:i];
      NSString *lab = [_locator labelForCharacterOffset:r.location mode:_pageNumberMode];
      [labels addObject:(lab != nil ? lab : @"")];
    }
  _pageLabels = labels;
  [_pageView setPageLabels:_pageLabels];
  [self updateAccessibilityPageInfo];
}

// EPUB Locators: calculated (and authored) page numbers must be exposed in the
// accessibility tree. With a bitmap renderer there is no live text tree, so we
// publish the visible page numbers on the window's accessibility value when the
// platform supplies one (NSWindow does not declare it on every GNUstep build).
- (void)updateAccessibilityPageInfo
{
  if (_pageLabels == nil || self.window == nil)
    return;
  SEL aSel = NSSelectorFromString(@"setAccessibilityValue:");
  if (aSel == NULL || [self.window respondsToSelector:aSel] == NO)
    return;
  NSUInteger left = [_pageView pageIndexForSpread:_currentSpread side:0];
  NSUInteger right = [_pageView pageIndexForSpread:_currentSpread side:1];
  NSString *l = (left != NSNotFound && left < [_pageLabels count]) ? [_pageLabels objectAtIndex:left] : @"";
  NSString *r = (right != NSNotFound && right < [_pageLabels count]) ? [_pageLabels objectAtIndex:right] : @"";
  NSString *val = [NSString stringWithFormat:@"Page numbers: left %@, right %@", l, r];
  NSMethodSignature *sig = [self.window methodSignatureForSelector:aSel];
  if (sig == nil)
    return;
  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  [inv setSelector:aSel];
  [inv setTarget:self.window];
  [inv setArgument:&val atIndex:2];
  [inv invoke];
}

- (void)updateThemeColors
{
  switch (_theme)
    {
      case 1:
        _backgroundColor = [NSColor colorWithCalibratedRed:0.96 green:0.91 blue:0.82 alpha:1.0];
        _textColor = [NSColor colorWithCalibratedRed:0.30 green:0.20 blue:0.12 alpha:1.0];
        break;
      case 2:
        _backgroundColor = [NSColor colorWithCalibratedRed:0.11 green:0.11 blue:0.13 alpha:1.0];
        _textColor = [NSColor colorWithCalibratedRed:0.80 green:0.80 blue:0.74 alpha:1.0];
        break;
      default:
        _backgroundColor = [NSColor colorWithCalibratedRed:0.98 green:0.98 blue:0.95 alpha:1.0];
        _textColor = [NSColor colorWithCalibratedRed:0.12 green:0.12 blue:0.12 alpha:1.0];
        break;
    }
}

- (NSString *)themeName
{
  return (_theme == 1) ? @"Sepia" : (_theme == 2) ? @"Night" : @"White";
}

- (void)applyFont
{
  // Scale from the original (unscaled) fonts in _baseText every time, so A− and
  // A+ are exact inverses and repeated presses do not compound on each other.
  // When the reader picked a font family, that family replaces the book's
  // default face while the existing bold/italic traits and the scaled size are
  // preserved; otherwise we keep the original (converter-chosen) family.
  CGFloat factor = _fontSize / 16.0;
  NSFontManager *fm = [NSFontManager sharedFontManager];
  NSUInteger len = [_baseText length];
  NSUInteger loc = 0;
  while (loc < len)
    {
      NSRange eff;
      NSDictionary *attrs = [_baseText attributesAtIndex:loc effectiveRange:&eff];
      id f = attrs[NSFontAttributeName];
      NSFontTraitMask traits = 0;
      CGFloat size = 16.0;
      if ([f isKindOfClass:[NSFont class]])
        {
          traits = [fm traitsOfFont:f];
          size = [f pointSize];
        }
      else
        {
          f = [NSFont userFontOfSize:16.0];
        }
      CGFloat newSize = size * factor;
      NSFont *nf = nil;
      if ([_fontFamily length] > 0)
        nf = [fm fontWithFamily:_fontFamily traits:traits weight:5 size:newSize];
      if (nf == nil)
        nf = [fm convertFont:f toSize:newSize];
      if (nf) [_fullText addAttribute:NSFontAttributeName value:nf range:eff];
      loc = NSMaxRange(eff);
    }
}

// Re-derive inter-line leading on the working text after a zoom/style change.
// Only the lineSpacing of each paragraph style is touched, so headings keep
// their spacing-before and paragraphs keep their spacing-after.
- (void)applyLineSpacing
{
  if (_fullText == nil)
    return;
  NSUInteger len = [_fullText length];
  NSUInteger loc = 0;
  while (loc < len)
    {
      NSRange eff;
      NSDictionary *attrs = [_fullText attributesAtIndex:loc effectiveRange:&eff];
      NSParagraphStyle *ps = attrs[NSParagraphStyleAttributeName];
      NSMutableParagraphStyle *mps = ([ps isKindOfClass:[NSMutableParagraphStyle class]]
                                      ? [ps mutableCopy]
                                      : [[NSMutableParagraphStyle alloc] init]);
      [mps setLineSpacing:_lineSpacing];
      [_fullText addAttribute:NSParagraphStyleAttributeName value:mps range:eff];
      loc = NSMaxRange(eff);
    }
}

- (void)applyTextColor
{
  [_fullText addAttribute:NSForegroundColorAttributeName
                    value:_textColor
                    range:NSMakeRange(0, [_fullText length])];
}

- (void)rebuildPaginator
{
  if (_pageView == nil || _fullText == nil) return;
  // Apply the user's page border margin before computing the layout area so
  // the renderer (which reads EPUBPageMargin) and the page text views agree.
  EPUBPageMargin = _pageMargin;
  [_pageView configureWithAttributedString:_fullText];
  [_pageView setBackgroundColor:_backgroundColor];
  [_pageView setThemeTextColor:_textColor];
  NSUInteger maxSpread = [_pageView spreadCount];
  if (maxSpread == 0) return;
  if (_currentSpread >= maxSpread) _currentSpread = maxSpread - 1;
  [_pageView showSpread:_currentSpread animated:NO];
  [self buildPageLabels];
  [self updateHighlights];
  [self reflectCurrentSpread];
}

// Re-paginate while keeping the reader on the same passage of text. We record
// the character offset at the top of the current spread, paginate the same
// attributed string again, then jump to the spread whose left page starts at or
// after that offset. The offset is a position in the EPUB reading text and is
// independent of font size, line spacing, margins and viewport, so the reader
// lands on the identical location after any presentation change instead of
// drifting to a different page.
- (void)rebuildPaginatorPreservingLocation
{
  NSUInteger anchor = NSNotFound;
  if (_pageView != nil && [_pageView pageCount] > 0)
    {
      NSUInteger leftPage = [_pageView pageIndexForSpread:_currentSpread side:0];
      if (leftPage == NSNotFound || leftPage >= [_pageView pageCount])
        leftPage = [_pageView pageIndexForSpread:_currentSpread side:1];
      if (leftPage == NSNotFound || leftPage >= [_pageView pageCount])
        leftPage = 0;
      anchor = [_pageView rangeForPage:leftPage].location;
    }
  [self rebuildPaginator];
  if (anchor != NSNotFound && [_pageView pageCount] > 0)
    {
      NSUInteger newLeft = 0;
      NSUInteger pc = [_pageView pageCount];
      for (NSUInteger i = 0; i < pc; i++)
        {
          if ([_pageView rangeForPage:i].location >= anchor)
            {
              newLeft = i;
              break;
            }
          newLeft = i;
        }
      _currentSpread = [_pageView spreadForPageIndex:newLeft];
      [_pageView showSpread:_currentSpread animated:NO];
      [self reflectCurrentSpread];
    }
}

// The families the system actually serves. We enumerate the font files in the
// system font directory (from fonts.conf) directly and ask fontconfig (fc-query)
// for each file's family name; this is deterministic regardless of which user
// the app runs as, unlike NSFontManager.availableFontFamilies (which mixes in
// the whole /usr/share/fonts universe and was observed dropping the system
// directory) or fc-list (whose directory coverage varies per user). The URW
// Base 35 files ship under their bare PostScript names (P052, C059, Z003, ...)
// but every reading app and user expects the traditional names, so we map the
// well-known Base 35 PostScript names to their standard human-readable families.
// Symbol faces (Dingbats, Standard Symbols) are omitted.
- (NSArray<NSString *> *)systemFontFamilyNames
{
  NSSet<NSString *> *dirs = [self configuredFontDirs];
  NSMutableArray<NSString *> *files = [NSMutableArray array];
  NSFileManager *fmgr = [NSFileManager defaultManager];
  NSArray<NSString *> *exts = @[ @"ttf", @"otf", @"ttc", @"pfa", @"pfb", @"dfont" ];
  for (NSString *dir in dirs)
    {
      NSDirectoryEnumerator *e = [fmgr enumeratorAtPath:dir];
      for (NSString *rel in e)
        {
          NSString *ext = [[rel pathExtension] lowercaseString];
          if ([exts containsObject:ext])
            [files addObject:[dir stringByAppendingPathComponent:rel]];
        }
    }
  if ([files count] == 0)
    return [self fallbackFontFamilies];

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:@"/bin/fc-query"];
  NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObject:@"--format=%{family}\n"];
  [args addObjectsFromArray:files];
  [task setArguments:args];
  NSPipe *outPipe = [NSPipe pipe];
  [task setStandardOutput:outPipe];
  [task setStandardError:[NSPipe pipe]];
  @try
    {
      [task launch];
    }
  @catch (NSException *e)
    {
      NSLog(@"Books fc-query launch failed: %@", e);
      return [self fallbackFontFamilies];
    }
  NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
  @try
    {
      [task waitUntilExit];
    }
  @catch (NSException *e)
    {
    }

  NSDictionary<NSString *, NSString *> *map = [self urwBase35Map];
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  for (NSString *line in [text componentsSeparatedByString:@"\n"])
    {
      NSString *fam = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([fam length] == 0)
        continue;
      // fc-query may report several comma-separated names ("Inter,Inter Medium");
      // the first is the canonical family.
      fam = [[fam componentsSeparatedByString:@","] firstObject];
      NSString *friendly = [map objectForKey:fam];
      if (friendly != nil)
        fam = friendly;
      if ([fam isEqualToString:@"Dingbats"] || [fam isEqualToString:@"Standard Symbols PS"])
        continue;
      if (![seen containsObject:fam])
        {
          [seen addObject:fam];
          [out addObject:fam];
        }
    }
  if ([out count] == 0)
    return [self fallbackFontFamilies];
  [out sortUsingSelector:@selector(caseInsensitiveCompare:)];
  return out;
}

// The standard URW Base 35 PostScript family names mapped to their traditional
// reading-font names. These are fixed identifiers defined by the URW Core Font
// replacement project, so mapping them is not hardcoding a font list.
- (NSDictionary<NSString *, NSString *> *)urwBase35Map
{
  return [NSDictionary dictionaryWithObjectsAndKeys:
    @"Century Schoolbook", @"C059",
    @"Dingbats", @"D050000L",
    @"Nimbus Sans L", @"N019003L",
    @"Nimbus Sans L", @"N019004L",
    @"Nimbus Roman", @"N021003L",
    @"Nimbus Roman", @"N021004L",
    @"Nimbus Mono", @"N022003L",
    @"Nimbus Mono", @"N022004L",
    @"Palladio", @"P052",
    @"Standard Symbols PS", @"S050000L",
    @"URW Chancery L", @"Z003",
    nil];
}

// Directories the system font server is configured to scan (from fonts.conf).
- (NSSet<NSString *> *)configuredFontDirs
{
  NSMutableSet<NSString *> *dirs = [NSMutableSet set];
  NSString *conf = @"/System/Library/Preferences/fonts.conf";
  NSData *confData = [NSData dataWithContentsOfFile:conf];
  NSString *c = confData ? [[NSString alloc] initWithData:confData encoding:NSUTF8StringEncoding] : nil;
  if (c != nil)
    {
      NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<dir>([^<]+)</dir>"
                                                                         options:0 error:NULL];
      for (NSTextCheckingResult *m in [re matchesInString:c options:0 range:NSMakeRange(0, [c length])])
        {
          NSString *d = [[c substringWithRange:[m rangeAtIndex:1]] stringByExpandingTildeInPath];
          if ([d length] > 0)
            [dirs addObject:d];
        }
    }
  if ([dirs count] == 0)
    [dirs addObject:@"/System/Library/Fonts"];
  return dirs;
}

// Last-resort list: what NSFontManager sees, minus the URW Base 35 PostScript
// bare names and symbol faces. Used only if fc-query is unavailable.
- (NSArray<NSString *> *)fallbackFontFamilies
{
  static NSSet<NSString *> *skip = nil;
  if (skip == nil)
    skip = [NSSet setWithObjects:
      @"Dingbats", @"Standard Symbols PS",
      @"C059", @"D050000L", @"P052", @"Z003",
      @"N019003L", @"N019004L", @"N021003L", @"N021004L",
      @"N022003L", @"N022004L", @"S050000L", nil];
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  NSFontManager *fm = [NSFontManager sharedFontManager];
  if ([fm respondsToSelector:@selector(availableFontFamilies)])
    {
      for (NSString *fam in [fm availableFontFamilies])
        if (![skip containsObject:fam])
          [out addObject:fam];
    }
  [out sortUsingSelector:@selector(caseInsensitiveCompare:)];
  return out;
}

- (void)buildWindow
{
  NSRect screen = [[NSScreen mainScreen] frame];
  // Size the window to fit the screen; requesting a larger size makes some
  // window managers silently clamp it, leaving GNUstep's -[win frame] stale and
  // the page view overflowing. Fitting the screen keeps the frame honest so the
  // page view (and resize reflow) tracks the real size.
  CGFloat w = MIN(1360.0, screen.size.width - 40.0);
  CGFloat h = MIN(720.0, screen.size.height - 80.0);
  if (w < 620.0) w = 620.0;
  if (h < 420.0) h = 420.0;
  NSRect r = NSMakeRect((screen.size.width - w) / 2.0,
                          (screen.size.height - h) / 2.0,
                          w, h);
  NSWindow *win = [[NSWindow alloc]
      initWithContentRect:r
                 styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                            NSResizableWindowMask | NSMiniaturizableWindowMask)
                   backing:NSBackingStoreBuffered
                     defer:NO];
  [win setTitle:[_libBook displayTitle]];
  [win setMinSize:NSMakeSize(620, 420)];
  [win setDelegate:self];
  self.window = win;

  NSView *content = [win contentView];
  NSRect bar = NSMakeRect(0, r.size.height - 44, r.size.width, 44);
  NSView *topBar = [[NSView alloc] initWithFrame:bar];
  [topBar setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];

  // Every toolbar control shares one height and baseline so the theme can render
  // adjacent (touching) controls as a single group. Controls are grouped by
  // function; within a group they touch exactly and groups are separated by a
  // constant gap (see -layoutToolbar).
  NSButton *contentsBtn = [self addBtn:topBar title:@"Contents" action:@selector(showTOC:) x:0 width:88];
  _backButton = [self addBtn:topBar title:@"<-" action:@selector(historyBack:) x:0 width:40];
  _forwardButton = [self addBtn:topBar title:@"->" action:@selector(historyForward:) x:0 width:40];
  NSButton *smallerBtn = [self addBtn:topBar title:@"A−" action:@selector(smaller:) x:0 width:40];
  NSButton *largerBtn = [self addBtn:topBar title:@"A+" action:@selector(larger:) x:0 width:40];
  _themeButton = [self addBtn:topBar
                         title:[NSString stringWithFormat:@"Theme: %@", [self themeName]]
                         action:@selector(cycleTheme:)
                              x:0 width:120];
  _pagesButton = [self addBtn:topBar
                         title:[self pagesButtonTitle]
                         action:@selector(cyclePageNumbers:)
                              x:0 width:108];
  _lineDownBtn = [self addBtn:topBar title:@"↕−" action:@selector(changeLineSpacing:) x:0 width:40];
  _lineUpBtn = [self addBtn:topBar title:@"↕+" action:@selector(changeLineSpacing:) x:0 width:40];
  _marginDownBtn = [self addBtn:topBar title:@"▭−" action:@selector(changeMargin:) x:0 width:40];
  _marginUpBtn = [self addBtn:topBar title:@"▭+" action:@selector(changeMargin:) x:0 width:40];

  // Font family drop-down: real families the system serves (no dingbat faces).
  _fontPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 9, 120, 26) pullsDown:NO];
  [_fontPopup setTarget:self];
  [_fontPopup setAction:@selector(changeFontFamily:)];
  [_fontPopup addItemWithTitle:@"Default"];
  NSSet<NSString *> *skip = [NSSet setWithObjects:@"Dingbats", @"Standard Symbols PS", nil];
  NSArray<NSString *> *fams = [self systemFontFamilyNames];
  for (NSString *fam in fams)
    {
      if ([skip containsObject:fam]) continue;
      [_fontPopup addItemWithTitle:fam];
    }
  if ([_fontFamily length] > 0)
    {
      NSInteger idx = [_fontPopup indexOfItemWithTitle:_fontFamily];
      if (idx >= 0) [_fontPopup selectItemAtIndex:idx];
    }
  else
    [_fontPopup selectItemAtIndex:0];
  [topBar addSubview:_fontPopup];

  // Single pencil button replaces the old Mark + Annotate buttons: it toggles
  // the annotations/bookmarks drawer (which lists both), matching Contents.
  _pencilButton = [self addBtn:topBar title:@"✎" action:@selector(showAnnotations:) x:0 width:40];
  [_pencilButton setKeyEquivalent:@"d"];
  [_pencilButton setKeyEquivalentModifierMask:NSEventModifierFlagCommand];

  // Scrubber + page field: drag to move through the book, or type a page number.
  _scrubber = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 9, 120, 26)];
  [_scrubber setTarget:self];
  [_scrubber setAction:@selector(scrubberMoved:)];
  [_scrubber setMinValue:0.0];
  [_scrubber setMaxValue:0.0];
  [_scrubber setContinuous:YES];
  [_scrubber setEnabled:NO];
  [topBar addSubview:_scrubber];

  _pageField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 9, 52, 26)];
  [_pageField setTarget:self];
  [_pageField setAction:@selector(pageFieldEntered:)];
  [_pageField setStringValue:@""];
  [_pageField setBezeled:YES];
  [topBar addSubview:_pageField];

  // Search field: type a word + Enter to list every match in the results drawer.
  _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 9, 150, 26)];
  [_searchField setTarget:self];
  [_searchField setAction:@selector(searchEntered:)];
  [_searchField setPlaceholderString:@"Search"];
  [topBar addSubview:_searchField];

  [self updatePagesButtonTitle];

  // Group the controls; touching controls form one visual group per the theme.
  _toolbarGroups = @[
    @[contentsBtn, _backButton, _forwardButton],
    @[smallerBtn, largerBtn],
    @[_themeButton, _pagesButton],
    @[_lineDownBtn, _lineUpBtn],
    @[_marginDownBtn, _marginUpBtn],
    @[_fontPopup],
    @[_pencilButton],
    @[_scrubber, _pageField],
    @[_searchField]
  ];
  [self layoutToolbar];

  [content addSubview:topBar];

  [self buildSearchDrawer];

  NSRect pv = NSMakeRect(0, 0, r.size.width, r.size.height - 44);
  _pageView = [[BookPageView alloc] initWithFrame:pv];
  [_pageView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
  [_pageView setDelegate:self];
  [content addSubview:_pageView];
  // The window manager may settle the window at a different size than requested;
  // re-apply the page-view layout shortly after show so it tracks the real size,
  // and keep polling since GNUstep may not post windowDidResize on WM resizes.
  [self performSelector:@selector(layoutForWindowSize) withObject:nil afterDelay:0.2];
  _sizePollTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                    target:self
                                                  selector:@selector(sizePollTick:)
                                                  userInfo:nil
                                                   repeats:YES];
}

- (NSButton *)addBtn:(NSView *)parent title:(NSString *)title action:(SEL)a x:(CGFloat)x
{
  return [self addBtn:parent title:title action:a x:x width:80];
}

- (NSButton *)addBtn:(NSView *)parent title:(NSString *)title action:(SEL)a x:(CGFloat)x width:(CGFloat)w
{
  NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x, 9, w, 26)];
  [b setBezelStyle:NSRoundedBezelStyle];
  [b setTitle:title];
  [b setTarget:self];
  [b setAction:a];
  [parent addSubview:b];
  return b;
}

// Lay the toolbar groups out left-to-right. Every control shares the same height
// and baseline; within a group controls touch exactly (no horizontal gap) so the
// theme treats them as one control, and groups are separated by a constant gap.
- (void)layoutToolbar
{
  CGFloat H = 26.0;
  CGFloat Y = (44.0 - H) / 2.0;
  CGFloat groupGap = 14.0;
  CGFloat x = 16.0;
  for (NSArray<NSView *> *group in _toolbarGroups)
    {
      for (NSView *v in group)
        {
          NSRect f = [v frame];
          f.origin.x = x;
          f.origin.y = Y;
          f.size.height = H;
          [v setFrame:f];
          x += f.size.width;
        }
      x += groupGap;
    }
}

- (void)showWithZoomFromRect:(NSRect)screenRect
{
  NSLog(@"showWithZoomFromRect entry, window=%p", self.window);
  [self rebuildPaginator];
  [_pageView showSpread:_currentSpread animated:NO];
  [self recordLocation];
  [self.window makeFirstResponder:_pageView];
  [self showWindow:nil];
  NSLog(@"showWithZoomFromRect after showWindow isVisible=%d", (int)[self.window isVisible]);
}

#pragma mark - Actions

- (void)showTOC:(id)sender
{
  if (_tocPanel == nil) _tocPanel = [[TOCPanelController alloc] init];
  [_tocPanel setDelegate:self];
  [_tocPanel toggleWithTOC:_epub.tableOfContents relativeToView:_pageView];
}

- (void)goDelta:(NSInteger)d
{
  NSUInteger max = [_pageView spreadCount];
  if (max == 0) return;
  [self recordLocation];
  NSInteger target = (NSInteger)_currentSpread + d;
  if (target < 0) target = 0;
  if (target >= (NSInteger)max) target = (NSInteger)max - 1;
  _currentSpread = (NSUInteger)target;
  [_pageView showSpread:_currentSpread animated:YES];
  [self reflectCurrentSpread];
  [self persist];
}

#pragma mark - History (Back / Forward)

// Record the spread we are about to leave so Back/Forward can return to it.
// Pushing a new location truncates any forward branch, matching browser history.
- (void)recordLocation
{
  if (_history == nil)
    {
      _history = [NSMutableArray array];
      _histPos = -1;
    }
  NSInteger cur = (NSInteger)_currentSpread;
  if (_histPos >= 0 && _histPos < (NSInteger)[_history count])
    {
      if ([[_history objectAtIndex:_histPos] integerValue] == cur)
        return;
    }
  if (_histPos < (NSInteger)[_history count] - 1)
    [_history removeObjectsInRange:NSMakeRange(_histPos + 1,
                                               [_history count] - (_histPos + 1))];
  [_history addObject:[NSNumber numberWithInteger:cur]];
  _histPos = (NSInteger)[_history count] - 1;
  [self updateHistoryButtons];
}

- (void)updateHistoryButtons
{
  BOOL canBack = (_histPos > 0);
  BOOL canFwd = (_history != nil && _histPos < (NSInteger)[_history count] - 1);
  [_backButton setEnabled:canBack];
  [_forwardButton setEnabled:canFwd];
}

- (void)historyBack:(id)sender
{
  if (_histPos <= 0)
    return;
  _histPos--;
  _currentSpread = [[_history objectAtIndex:_histPos] unsignedIntegerValue];
  [_pageView showSpread:_currentSpread animated:NO];
  [self reflectCurrentSpread];
  [self persist];
  [self updateHistoryButtons];
}

- (void)historyForward:(id)sender
{
  if (_history == nil || _histPos >= (NSInteger)[_history count] - 1)
    return;
  _histPos++;
  _currentSpread = [[_history objectAtIndex:_histPos] unsignedIntegerValue];
  [_pageView showSpread:_currentSpread animated:NO];
  [self reflectCurrentSpread];
  [self persist];
  [self updateHistoryButtons];
}

- (void)smaller:(id)sender
{
  _fontSize -= 2.0;
  if (_fontSize < 9.0) _fontSize = 9.0;
  [self applyFont];
  [self rebuildPaginatorPreservingLocation];
  [self persist];
}

- (void)larger:(id)sender
{
  _fontSize += 2.0;
  if (_fontSize > 42.0) _fontSize = 42.0;
  [self applyFont];
  [self rebuildPaginatorPreservingLocation];
  [self persist];
}

- (void)cycleTheme:(id)sender
{
  _theme = (_theme + 1) % 3;
  [self updateThemeColors];
  [self applyTextColor];
  [_themeButton setTitle:[NSString stringWithFormat:@"Theme: %@", [self themeName]]];
  [self rebuildPaginatorPreservingLocation];
  [self persist];
}

- (NSString *)pagesButtonTitle
{
  switch (_pageNumberMode)
    {
      case 1: return @"Pages: Authored";
      case 2: return @"Pages: Off";
      default: return @"Pages: Calc";
    }
}

- (void)updatePagesButtonTitle
{
  [_pagesButton setTitle:[self pagesButtonTitle]];
}

// EPUB Locators UX: let the reader choose authored page numbers, calculated
// page numbers, or none at all. The footer recomputes from the same positions.
- (void)cyclePageNumbers:(id)sender
{
  _pageNumberMode = (_pageNumberMode + 1) % 3;
  _libBook.pageNumberMode = _pageNumberMode;
  [self updatePagesButtonTitle];
  [self buildPageLabels];
  [_pageView showSpread:_currentSpread animated:NO];
  [self reflectCurrentSpread];
  [self persist];
}

#pragma mark - Presentation controls (line spacing, margin, font)

- (void)changeLineSpacing:(id)sender
{
  // Coarse steps: each press changes leading by 3pt so the effect is obvious.
  CGFloat step = 3.0;
  if (sender == _lineDownBtn)
    _lineSpacing -= step;
  else
    _lineSpacing += step;
  if (_lineSpacing < 0.0) _lineSpacing = 0.0;
  if (_lineSpacing > 24.0) _lineSpacing = 24.0;
  _libBook.lineSpacing = _lineSpacing;
  [self applyLineSpacing];
  [self rebuildPaginatorPreservingLocation];
  [self persist];
}

- (void)changeMargin:(id)sender
{
  // Coarse steps: each press changes the page border margin by 8pt.
  CGFloat step = 8.0;
  if (sender == _marginDownBtn)
    _pageMargin -= step;
  else
    _pageMargin += step;
  if (_pageMargin < 6.0) _pageMargin = 6.0;
  if (_pageMargin > 96.0) _pageMargin = 96.0;
  _libBook.pageMargin = _pageMargin;
  [self rebuildPaginatorPreservingLocation];
  [self persist];
}

- (void)changeFontFamily:(id)sender
{
  NSString *title = [_fontPopup titleOfSelectedItem];
  if ([title isEqualToString:@"Default"])
    _fontFamily = nil;
  else
    _fontFamily = title;
  _libBook.fontFamily = [_fontFamily copy];
  [self applyFont];
  [self rebuildPaginatorPreservingLocation];
  // Force a fresh paint with the new font regardless of whether the spread index moved.
  [_pageView showSpread:_currentSpread animated:NO];
  [self persist];
}

#pragma mark - Scrubber + page-number field

// Keep the slider and page-number field in sync with the visible spread.
- (void)reflectCurrentSpread
{
  NSUInteger max = [_pageView spreadCount];
  if (_scrubber != nil)
    {
      if (max > 0)
        {
          [_scrubber setEnabled:YES];
          [_scrubber setMaxValue:(double)(max - 1)];
          [_scrubber setDoubleValue:(double)_currentSpread];
        }
      else
        {
          [_scrubber setEnabled:NO];
        }
    }
  if (_pageField != nil && _pageLabels != nil)
    {
      NSUInteger rightIdx = [_pageView pageIndexForSpread:_currentSpread side:1];
      NSUInteger leftIdx = [_pageView pageIndexForSpread:_currentSpread side:0];
      NSString *lab = nil;
      if (rightIdx != NSNotFound && rightIdx < [_pageLabels count])
        lab = [_pageLabels objectAtIndex:rightIdx];
      if ([lab length] == 0 && leftIdx != NSNotFound && leftIdx < [_pageLabels count])
        lab = [_pageLabels objectAtIndex:leftIdx];
      [_pageField setStringValue:(lab != nil ? lab : @"")];
    }
}

- (void)scrubberMoved:(id)sender
{
  if (_scrubber == nil)
    return;
  NSInteger v = (NSInteger)[_scrubber doubleValue];
  if (v < 0) v = 0;
  NSUInteger max = [_pageView spreadCount];
  if (max == 0) return;
  if ((NSUInteger)v >= max) v = (NSInteger)max - 1;
  _currentSpread = (NSUInteger)v;
  [_pageView showSpread:_currentSpread animated:NO];
  [self persist];
  [self reflectCurrentSpread];
}

// Enter in the page-number field jumps to the first visual page whose label is
// at least the typed number (exact match for numeric/calculated labels).
- (void)pageFieldEntered:(id)sender
{
  if (_pageField == nil)
    return;
  NSInteger n = (NSInteger)[[_pageField stringValue] integerValue];
  if (n < 1) n = 1;
  if (_pageLabels == nil)
    [self buildPageLabels];
  NSUInteger pc = [_pageView pageCount];
  if (pc == 0)
    return;
  NSUInteger target = pc - 1;
  for (NSUInteger i = 0; i < pc; i++)
    {
      NSString *lab = [_pageLabels objectAtIndex:i];
      NSInteger v = [lab integerValue];
      if (v >= n)
        {
          target = i;
          break;
        }
    }
  _currentSpread = [_pageView spreadForPageIndex:target];
  [self recordLocation];
  [_pageView showSpread:_currentSpread animated:YES];
  [self persist];
  [self reflectCurrentSpread];
}

- (void)persist
{
  _libBook.lastSpreadIndex = _currentSpread;
  _libBook.fontSize = _fontSize;
  _libBook.theme = _theme;
  _libBook.lineSpacing = _lineSpacing;
  _libBook.pageMargin = _pageMargin;
  _libBook.fontFamily = [_fontFamily copy];
  _libBook.pageNumberMode = _pageNumberMode;
  [[LibraryStore sharedStore] save];
}

#pragma mark - BookPageViewDelegate

- (void)pageViewDidRequestNext:(BookPageView *)view { [self goDelta:1]; }
- (void)pageViewDidRequestPrevious:(BookPageView *)view { [self goDelta:-1]; }

// Ctrl + scroll wheel zooms the text by nudging the same _fontSize the A+/A-
// buttons use, then re-paginates so the new size flows through every page.
- (void)pageView:(BookPageView *)view fontSizeDelta:(CGFloat)delta
{
  _fontSize += delta * 2.0;
  if (_fontSize < 9.0) _fontSize = 9.0;
  if (_fontSize > 42.0) _fontSize = 42.0;
  [self applyFont];
  [self rebuildPaginatorPreservingLocation];
  [_pageView showSpread:_currentSpread animated:NO];
  [self persist];
}

#pragma mark - TOCPanelDelegate

- (void)tocDidSelectEntry:(EPUBTOCEntry *)entry
{
  NSString *abs = [_epub absolutePathForContent:entry.contentPath];
  if (abs == nil) { [_tocPanel hide]; return; }
  NSNumber *start = [_docStart objectForKey:[abs lastPathComponent]];
  if (start)
    {
      NSUInteger page = [_pageView pageForCharacterIndex:[start unsignedIntegerValue]];
      [self recordLocation];
      _currentSpread = [_pageView spreadForPageIndex:page];
      [_pageView showSpread:_currentSpread animated:YES];
      [self reflectCurrentSpread];
      [self persist];
    }
  [_tocPanel hide];
}

#pragma mark - NSWindowDelegate

// GNUstep does not always resize the window's content view (and thus the page
// view) to track the actual on-screen window size, so the page view can overflow
// the window and never reflow. Force the page view to fill the current content
// area on every resize; the heavy re-pagination is still deferred below.
- (void)layoutForWindowSize
{
  NSWindow *win = self.window;
  if (win == nil)
    return;
  NSRect cr = [win contentRectForFrameRect:[win frame]];
  if (cr.size.width < 1.0 || cr.size.height < 1.0)
    return;
  _lastContentSize = cr.size;
  // Do NOT resize the content view here: writing it back from the content rect
  // feeds into contentRectForFrameRect: and makes the reported size drift every
  // tick, so sizePollTick never sees a stable size and re-paginates forever
  // (pinning the CPU). The content view is owned by the window; we only size our
  // own page view inside it.
  NSRect pv = NSMakeRect(0, 0, cr.size.width, cr.size.height - 44.0);
  if (!NSEqualRects([_pageView frame], pv))
    [_pageView setFrame:pv];
}

// The window manager can resize the window without GNUstep ever posting
// windowDidResize (or with a stale -[win frame]), so check the real size on a
// low-frequency timer and reflow when it genuinely changes.
- (void)sizePollTick:(NSTimer *)t
{
  NSWindow *win = self.window;
  if (win == nil || ![win isVisible])
    return;
  NSRect cr = [win contentRectForFrameRect:[win frame]];
  if (cr.size.width < 1.0 || cr.size.height < 1.0)
    return;
  if (NSEqualSizes(cr.size, _lastContentSize))
    return;
  _lastContentSize = cr.size;
  [self layoutForWindowSize];
  [_resizeTimer invalidate];
  _resizeTimer = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                  target:self
                                                selector:@selector(resizeRelayout:)
                                                userInfo:nil
                                                 repeats:NO];
}

- (void)windowDidResize:(NSNotification *)note
{
  [self layoutForWindowSize];
  // Re-paginating on every resize tick blocks the run loop and makes the window
  // feel frozen while the user drags the size grip. Defer the heavy work until
  // the resize settles, and show a busy cursor while it actually runs.
  [_resizeTimer invalidate];
  _resizeTimer = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                  target:self
                                                selector:@selector(resizeRelayout:)
                                                userInfo:nil
                                                 repeats:NO];
}

// A tiny watch cursor used to signal that re-pagination is in progress. GNUstep
// ships no built-in wait cursor, so we draw one.
- (NSCursor *)busyCursor
{
  static NSCursor *c = nil;
  if (c != nil)
    return c;
  NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
  [img lockFocus];
  [[NSColor clearColor] set];
  NSRectFill(NSMakeRect(0, 0, 16, 16));
  [[NSColor blackColor] set];
  NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2.5, 2.5, 11, 11)];
  [p setLineWidth:1.5];
  [p stroke];
  [p removeAllPoints];
  [p moveToPoint:NSMakePoint(8, 8)];
  [p lineToPoint:NSMakePoint(8, 4.5)];
  [p stroke];
  [img unlockFocus];
  c = [[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(8, 8)];
  return c;
}

- (void)resizeRelayout:(NSTimer *)timer
{
  _resizeTimer = nil;
  [[self busyCursor] set];
  [self rebuildPaginatorPreservingLocation];
  [[NSCursor arrowCursor] set];
}

- (void)windowWillClose:(NSNotification *)note
{
  [_resizeTimer invalidate];
  _resizeTimer = nil;
  [_sizePollTimer invalidate];
  _sizePollTimer = nil;
  [self persist];
  [_epub cleanupExtraction];
}

#pragma mark - Search

// Results drawer (right edge) listing every occurrence of the search term. Each
// row shows the page the match falls on and a short snippet; double-clicking or
// pressing Return jumps straight to that occurrence.
- (void)buildSearchDrawer
{
  _searchDrawer = [[NSDrawer alloc] initWithContentSize:NSMakeSize(340, 400) preferredEdge:NSMaxXEdge];
  NSView *dv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 400)];

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 28, 340, 372)];
  [sv setHasVerticalScroller:YES];
  [sv setHasHorizontalScroller:NO];
  [sv setBorderType:NSBezelBorder];

  _searchTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 340, 372)];
  NSTableColumn *cPage = [[NSTableColumn alloc] initWithIdentifier:@"page"];
  [cPage setTitle:@"Page"];
  [cPage setWidth:64];
  [cPage setResizingMask:NSTableColumnAutoresizingMask];
  NSTableColumn *cCtx = [[NSTableColumn alloc] initWithIdentifier:@"ctx"];
  [cCtx setTitle:@"Context"];
  [cCtx setWidth:272];
  [cCtx setResizingMask:NSTableColumnAutoresizingMask];
  [_searchTable addTableColumn:cPage];
  [_searchTable addTableColumn:cCtx];
  [_searchTable setDataSource:self];
  [_searchTable setDelegate:self];
  [_searchTable setAction:@selector(searchJump:)];
  [_searchTable setDoubleAction:@selector(searchJump:)];
  [_searchTable setTarget:self];
  [sv setDocumentView:_searchTable];
  [dv addSubview:sv];

  _searchStatus = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 4, 324, 20)];
  [_searchStatus setBezeled:NO];
  [_searchStatus setDrawsBackground:NO];
  [_searchStatus setEditable:NO];
  [_searchStatus setSelectable:NO];
  [_searchStatus setStringValue:@""];
  [dv addSubview:_searchStatus];

  [_searchDrawer setContentView:dv];
  [_searchDrawer setParentWindow:self.window];
}

// Case-insensitive substring scan over the whole book text; every hit is stored
// as a character range so we can later map it back to its page.
- (void)searchEntered:(id)sender
{
  NSString *q = [[_searchField stringValue]
    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([q length] == 0)
    {
      _searchMatches = @[];
      [_searchTable reloadData];
      [_searchStatus setStringValue:@""];
      [_searchDrawer close];
      return;
    }
  NSString *text = [_fullText string];
  NSString *lower = [text lowercaseString];
  NSString *lq = [q lowercaseString];
  NSMutableArray *matches = [NSMutableArray array];
  NSRange r = NSMakeRange(0, [lower length]);
  while (r.location < [lower length])
    {
      NSRange found = [lower rangeOfString:lq options:0 range:r];
      if (found.location == NSNotFound)
        break;
      [matches addObject:[NSValue valueWithRange:found]];
      NSUInteger next = found.location + found.length;
      if (next >= [lower length])
        break;
      r.location = next;
      r.length = [lower length] - next;
      if ([matches count] >= 2000)
        break;
    }
  _searchMatches = matches;
  [_searchTable reloadData];
  [self updateSearchStatus];
  if ([matches count] > 0)
    [_searchDrawer open];
  else
    [_searchDrawer close];
}

- (void)updateSearchStatus
{
  NSUInteger n = [_searchMatches count];
  if (n == 0)
    [_searchStatus setStringValue:@"No matches"];
  else
    [_searchStatus setStringValue:[NSString stringWithFormat:@"%lu match%@",
                                    (unsigned long)n, n == 1 ? @"" : @"es"]];
}

- (void)searchJump:(id)sender
{
  NSInteger row = [_searchTable clickedRow];
  if (row < 0)
    row = [_searchTable selectedRow];
  if (row < 0 || row >= (NSInteger)[_searchMatches count])
    return;
  NSRange range = [[_searchMatches objectAtIndex:row] rangeValue];
  NSUInteger page = [_pageView pageForCharacterIndex:range.location];
  [self recordLocation];
  _currentSpread = [_pageView spreadForPageIndex:page];
  [_pageView showSpread:_currentSpread animated:NO];
  [self reflectCurrentSpread];
  [self persist];
}

- (NSString *)searchSnippetForRange:(NSRange)range inText:(NSString *)text
{
  NSInteger start = MAX(0, (NSInteger)range.location - 24);
  NSInteger end = MIN((NSInteger)[text length], (NSInteger)(range.location + range.length + 40));
  NSRange sr = NSMakeRange(start, end - start);
  NSMutableString *s = [[text substringWithRange:sr] mutableCopy];
  [s replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, [s length])];
  [s replaceOccurrencesOfString:@"\r" withString:@" " options:0 range:NSMakeRange(0, [s length])];
  if (start > 0)
    [s insertString:@"…" atIndex:0];
  if (end < (NSInteger)[text length])
    [s appendString:@"…"];
  return s;
}

#pragma mark - NSTableViewDataSource / NSTableViewDelegate

// The results list is read-only; refusing edit keeps a double-click from
// dropping into cell-editing mode so it can fire the jump action instead.
- (BOOL)tableView:(NSTableView *)tv shouldEditTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
  return NO;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
  if (tv == _annoTable)
    return (NSInteger)[_annotations count];
  return (NSInteger)[_searchMatches count];
}

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
  if (tv == _annoTable)
    {
      if (row < 0 || row >= (NSInteger)[_annotations count])
        return @"";
      EPUBAnnotation *a = [_annotations objectAtIndex:row];
      NSString *text = [_fullText string];
      NSRange range = NSMakeRange(a.absStart, a.absEnd - a.absStart);
      if (a.absEnd <= a.absStart || a.absStart == NSNotFound)
        range = NSMakeRange(0, 0);
      if ([[col identifier] isEqualToString:@"page"])
        {
          NSUInteger page = (range.length > 0)
            ? [_pageView pageForCharacterIndex:range.location]
            : (a.absStart == NSNotFound ? 0 : [_pageView pageForCharacterIndex:a.absStart]);
          NSString *lab = [NSString stringWithFormat:@"%lu", (unsigned long)(page + 1)];
          if (_locator && range.length > 0)
            {
              NSString *l = [_locator labelForCharacterOffset:range.location mode:_pageNumberMode];
              if ([l length] > 0) lab = l;
            }
          return lab;
        }
      if ([[col identifier] isEqualToString:@"kind"])
        {
          if (a.motivation == EPUBAnnotationBookmarking) return @"B";
          if (a.motivation == EPUBAnnotationCommenting) return @"N";
          return @"H";
        }
      // Context column: the quoted text, or the note if present.
      NSString *disp = (a.note != nil && [a.note length] > 0) ? a.note : a.exact;
      if (disp == nil) disp = @"";
      if (range.length > 0 && [disp length] == 0)
        disp = [text substringWithRange:range];
      NSMutableString *s = [[disp stringByReplacingOccurrencesOfString:@"\n"
                                                              withString:@" "] mutableCopy];
      if ([s length] > 120) s = [[s substringToIndex:120] mutableCopy];
      return s;
    }

  if (row < 0 || row >= (NSInteger)[_searchMatches count])
    return @"";
  NSRange range = [[_searchMatches objectAtIndex:row] rangeValue];
  NSString *text = [_fullText string];
  if ([[col identifier] isEqualToString:@"page"])
    {
      NSUInteger page = [_pageView pageForCharacterIndex:range.location];
      NSString *lab = [NSString stringWithFormat:@"%lu", (unsigned long)(page + 1)];
      if (_locator)
        {
          NSString *l = [_locator labelForCharacterOffset:range.location mode:_pageNumberMode];
          if ([l length] > 0)
            lab = l;
        }
      return lab;
    }
  return [self searchSnippetForRange:range inText:text];
}

- (LibraryBook *)libraryBook
{
  return _libBook;
}

#pragma mark - Annotations

// Resolve each loaded annotation's document-relative offsets back to absolute
// offsets in the concatenated reading text, using the spine map built while
// parsing. Annotations whose source document is no longer present are marked
// unmapped (absStart = NSNotFound) and skipped when painting or jumping.
- (void)mapLoadedAnnotations
{
  for (EPUBAnnotation *a in _annotations)
    {
      NSString *key = [a.source lastPathComponent];
      NSNumber *base = [_docStart objectForKey:key];
      if (base == nil)
        {
          a.absStart = NSNotFound;
          a.absEnd = 0;
          continue;
        }
      a.absStart = [base unsignedIntegerValue] + a.docStart;
      a.absEnd = [base unsignedIntegerValue] + a.docEnd;
    }
}

// Which spine document contains a given reading-text offset: the one with the
// greatest start offset not exceeding it.
- (NSString *)docKeyForCharOffset:(NSUInteger)offset
{
  NSString *best = nil;
  NSUInteger bestOff = 0;
  for (NSString *key in _docStart)
    {
      NSUInteger o = [_docStart[key] unsignedIntegerValue];
      if (o <= offset && (best == nil || o >= bestOff))
        {
          best = key;
          bestOff = o;
        }
    }
  return best;
}

// Push the visible highlights to the page view. Bookmarks have zero length and
// are not painted, only listed.
- (void)updateHighlights
{
  NSMutableArray *arr = [NSMutableArray array];
  for (EPUBAnnotation *a in _annotations)
    {
      if (a.absEnd <= a.absStart || a.absStart == NSNotFound)
        continue;
      NSColor *c = [EPUBAnnotation colorForLabel:a.colorLabel];
      [arr addObject:@{ @"range": [NSValue valueWithRange:NSMakeRange(a.absStart,
                                                                      a.absEnd - a.absStart)],
                        @"color": c }];
    }
  [_pageView setHighlights:arr];
}

- (void)saveAnnotations
{
  [_annoStore saveAnnotations:_annotations];
}

// A drag over the page selected a run of text: turn it into a highlight
// annotation anchored with the standard TextQuote + TextPosition selectors.
- (void)pageView:(BookPageView *)view didSelectRange:(NSRange)range
{
  if (range.length == 0)
    return;
  NSString *text = [_fullText string];
  NSString *docKey = [self docKeyForCharOffset:range.location];
  if (docKey == nil)
    return;
  NSUInteger base = [_docStart[docKey] unsignedIntegerValue];
  // Keep the selection inside the document it starts in.
  NSUInteger docLen = [text length] - base;
  for (NSNumber *n in [_docStart allValues])
    {
      NSUInteger o = [n unsignedIntegerValue];
      if (o > base && (o - base) < docLen)
        docLen = o - base;
    }
  NSUInteger relStart = range.location - base;
  NSUInteger relEnd = MIN(range.location + range.length, base + docLen) - base;
  if (relEnd <= relStart)
    return;

  EPUBAnnotation *a = [[EPUBAnnotation alloc] init];
  a.motivation = EPUBAnnotationHighlighting;
  a.source = _docRelPaths[docKey] ?: docKey;
  a.docStart = relStart;
  a.docEnd = relEnd;
  a.absStart = base + relStart;
  a.absEnd = base + relEnd;
  a.exact = [text substringWithRange:NSMakeRange(a.absStart, a.absEnd - a.absStart)];
  a.colorLabel = _highlightColorLabel;
  [_annotations addObject:a];
  [self saveAnnotations];
  [self updateHighlights];
  [_annoTable reloadData];
  [self updateAnnoStatus];
  [self showAnnotations:nil];
}

// Bookmark the current spread's reading position (Cmd-D).
- (void)openAnnotations
{
  if (_annoDrawer == nil)
    [self buildAnnotationDrawer];
  [_annoTable reloadData];
  [self updateAnnoStatus];
  [_annoDrawer open];
}

- (void)showAnnotations:(id)sender
{
  // Single pencil button: toggle the annotations drawer like the Contents
  // button toggles the TOC. Reload first so the list is current on open.
  if (_annoDrawer == nil)
    [self buildAnnotationDrawer];
  [_annoTable reloadData];
  [self updateAnnoStatus];
  [_annoDrawer toggle:self];
}

// Results drawer (right edge) listing every annotation and bookmark. Each row
// shows the page, a kind glyph and the quote or note; double-click jumps to it.
- (void)buildAnnotationDrawer
{
  _annoDrawer = [[NSDrawer alloc] initWithContentSize:NSMakeSize(380, 560)
                                        preferredEdge:NSMaxXEdge];
  NSView *dv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 560)];

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 28, 380, 306)];
  [sv setHasVerticalScroller:YES];
  [sv setBorderType:NSBezelBorder];

  _annoTable = [[BooksAnnoTableView alloc] initWithFrame:NSMakeRect(0, 0, 380, 306)];
  __weak typeof(self) weakSelf = self;
  [_annoTable setDeleteBlock:^{
    [weakSelf annoDelete:weakSelf.annoTable];
  }];
  NSTableColumn *cKind = [[NSTableColumn alloc] initWithIdentifier:@"kind"];
  [cKind setTitle:@""];
  [cKind setWidth:24];
  NSTableColumn *cPage = [[NSTableColumn alloc] initWithIdentifier:@"page"];
  [cPage setTitle:@"Page"];
  [cPage setWidth:64];
  NSTableColumn *cCtx = [[NSTableColumn alloc] initWithIdentifier:@"ctx"];
  [cCtx setTitle:@"Note / Quote"];
  [cCtx setWidth:288];
  [_annoTable addTableColumn:cKind];
  [_annoTable addTableColumn:cPage];
  [_annoTable addTableColumn:cCtx];
  [_annoTable setDataSource:self];
  [_annoTable setDelegate:self];
  [_annoTable setAction:@selector(annoJump:)];
  [_annoTable setDoubleAction:@selector(annoJump:)];
  [_annoTable setTarget:self];
  [sv setDocumentView:_annoTable];
  [dv addSubview:sv];

  // Note editor: a scrollable, multiline text view (about 10 lines tall) so the
  // user can write long notes; scrollbars appear once the text overflows.
  NSScrollView *noteSV = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(8, 342, 364, 200)];
  [noteSV setHasVerticalScroller:YES];
  [noteSV setHasHorizontalScroller:YES];
  [noteSV setBorderType:NSBezelBorder];
  [noteSV setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  _annoNote = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 364, 200)];
  [_annoNote setMinSize:NSMakeSize(0, 200)];
  [_annoNote setMaxSize:NSMakeSize(1.0e7, 1.0e7)];
  [_annoNote setVerticallyResizable:YES];
  [_annoNote setHorizontallyResizable:YES];
  [_annoNote setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [[_annoNote textContainer] setWidthTracksTextView:YES];
  [_annoNote setDelegate:self];
  [_annoNote setRichText:NO];
  [_annoNote setFont:[NSFont userFontOfSize:0]];
  [noteSV setDocumentView:_annoNote];
  [dv addSubview:noteSV];

  _annoStatus = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 6, 360, 20)];
  [_annoStatus setBezeled:NO];
  [_annoStatus setDrawsBackground:NO];
  [_annoStatus setEditable:NO];
  [_annoStatus setSelectable:NO];
  [dv addSubview:_annoStatus];

  [_annoDrawer setContentView:dv];
  [_annoDrawer setParentWindow:self.window];
}

- (void)updateAnnoStatus
{
  NSUInteger n = [_annotations count];
  [_annoStatus setStringValue:[NSString stringWithFormat:@"%lu annotation%@",
                                                        (unsigned long)n, n == 1 ? @"" : @"s"]];
}

- (void)annoJump:(id)sender
{
  NSInteger row = [_annoTable clickedRow];
  if (row < 0)
    row = [_annoTable selectedRow];
  if (row < 0 || row >= (NSInteger)[_annotations count])
    return;
  EPUBAnnotation *a = [_annotations objectAtIndex:row];
  if (a.absStart == NSNotFound)
    return;
  NSUInteger page = [_pageView pageForCharacterIndex:a.absStart];
  [self recordLocation];
  _currentSpread = [_pageView spreadForPageIndex:page];
  [_pageView showSpread:_currentSpread animated:NO];
  [self reflectCurrentSpread];
  [self persist];
  _selectedAnno = a;
  [self loadNoteForSelected];
}

- (void)annoDelete:(id)sender
{
  NSInteger row = [_annoTable selectedRow];
  if (row < 0 || row >= (NSInteger)[_annotations count])
    return;
  [_annotations removeObjectAtIndex:row];
  [self saveAnnotations];
  [self updateHighlights];
  [_annoTable reloadData];
  [self updateAnnoStatus];
}

- (void)commitNote
{
  if (_selectedAnno == nil)
    return;
  NSString *raw = [_annoNote string];
  NSString *n = [raw stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (_annoNotePlaceholderActive)
    n = @"";
  _selectedAnno.note = ([n length] > 0) ? [n copy] : nil;
  // A note upgrades a plain highlight into a commenting annotation.
  if ([n length] > 0 && _selectedAnno.motivation == EPUBAnnotationHighlighting)
    _selectedAnno.motivation = EPUBAnnotationCommenting;
  _selectedAnno.modified = [NSDate date];
  [self saveAnnotations];
  [self updateHighlights];
  [_annoTable reloadData];
}

- (void)annoNoteChanged:(id)sender
{
  [self commitNote];
}

- (void)textDidChange:(NSNotification *)note
{
  if ([note object] == _annoNote)
    [self commitNote];
}

- (void)showNotePlaceholder
{
  _annoNotePlaceholderActive = YES;
  [_annoNote setTextColor:[NSColor disabledControlTextColor]];
  [_annoNote setString:@"Add a note for the selected item…"];
  [[_annoNote textStorage] setFont:[NSFont userFontOfSize:0]];
}

- (BOOL)textShouldBeginEditing:(NSText *)textObject
{
  if (textObject == _annoNote && _annoNotePlaceholderActive)
    {
      _annoNotePlaceholderActive = NO;
      [_annoNote setTextColor:[NSColor controlTextColor]];
      [_annoNote setString:@""];
    }
  return YES;
}

- (void)loadNoteForSelected
{
  NSInteger row = [_annoTable selectedRow];
  if (row < 0 || row >= (NSInteger)[_annotations count])
    {
      _selectedAnno = nil;
      [self showNotePlaceholder];
      return;
    }
  _selectedAnno = [_annotations objectAtIndex:row];
  NSString *note = _selectedAnno.note;
  if ([note length] == 0)
    [self showNotePlaceholder];
  else
    {
      _annoNotePlaceholderActive = NO;
      [_annoNote setTextColor:[NSColor controlTextColor]];
      [_annoNote setString:note];
    }
}

#pragma mark - NSTableViewDelegate (selection)

- (void)tableViewSelectionDidChange:(NSNotification *)note
{
  if ([note object] == _annoTable)
    [self loadNoteForSelected];
}

@end
