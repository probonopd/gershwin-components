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
#import "EPUBPaginator.h"
#import "EPUBPageRenderer.h"
#import "EPUBHTMLConverter.h"
#import "BookPageView.h"
#import "TOCPanelController.h"

@interface BookReaderController () <BookPageViewDelegate, NSWindowDelegate, TOCPanelDelegate>
@property (nonatomic, strong) LibraryBook *libBook;
@property (nonatomic, strong) EPUBBook *epub;
@property (nonatomic, strong) NSMutableAttributedString *fullText;
@property (nonatomic, strong) NSAttributedString *baseText;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *docStart;
@property (nonatomic, strong) EPUBPageRenderer *renderer;
@property (nonatomic, strong) BookPageView *pageView;
@property (nonatomic, strong) TOCPanelController *tocPanel;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) NSInteger theme;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, strong) NSColor *textColor;
@property (nonatomic, assign) NSUInteger currentSpread;
@property (nonatomic, strong) NSButton *themeButton;
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
      _docStart = [NSMutableDictionary dictionary];
      _renderer = [[EPUBPageRenderer alloc] init];
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
  for (NSString *docAbs in _epub.spine)
    {
      NSData *data = [NSData dataWithContentsOfFile:docAbs];
      if (data == nil) continue;
      NSURL *baseURL = [NSURL fileURLWithPath:[docAbs stringByDeletingLastPathComponent]];
      NSAttributedString *part = [EPUBHTMLConverter
          attributedStringFromXHTMLAtPath:docAbs
                                    baseURL:baseURL
                             containerRoot:_epub.extractedRoot
                                     error:NULL];
      if ([part length] > 0)
        {
          [_docStart setObject:@(offset) forKey:[docAbs lastPathComponent]];
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
  return YES;
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
  CGFloat factor = _fontSize / 16.0;
  NSUInteger len = [_baseText length];
  NSUInteger loc = 0;
  while (loc < len)
    {
      NSRange eff;
      NSDictionary *attrs = [_baseText attributesAtIndex:loc effectiveRange:&eff];
      id f = attrs[NSFontAttributeName];
      if (f == nil || ![f isKindOfClass:[NSFont class]])
        f = [NSFont userFontOfSize:16.0];
      NSFont *nf = [[NSFontManager sharedFontManager] convertFont:f toSize:[f pointSize] * factor];
      if (nf) [_fullText addAttribute:NSFontAttributeName value:nf range:eff];
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
  NSSize cs = [_pageView contentSize];
  // The renderer insets the text by EPUBPageMargin on every side, so paginate
  // using that same inner area; otherwise the last lines overflow and get cut.
  NSSize textArea = NSMakeSize(MAX(1.0, cs.width - 2.0 * EPUBPageMargin),
                               MAX(1.0, cs.height - 2.0 * EPUBPageMargin));
  EPUBPaginator *p = [[EPUBPaginator alloc]
      initWithAttributedString:_fullText
                      pageRect:NSMakeRect(0, 0, textArea.width, textArea.height)];
  [_pageView configureWithAttributedString:_fullText paginator:p renderer:_renderer];
  [_pageView setBackgroundColor:_backgroundColor];
  [_pageView setThemeTextColor:_textColor];
  NSUInteger maxSpread = [_pageView spreadCount];
  if (maxSpread == 0) return;
  if (_currentSpread >= maxSpread) _currentSpread = maxSpread - 1;
  [_pageView showSpread:_currentSpread animated:NO];
}

- (void)buildWindow
{
  NSRect screen = [[NSScreen mainScreen] frame];
  NSRect r = NSMakeRect((screen.size.width - 1024) / 2.0,
                        (screen.size.height - 720) / 2.0,
                        1024, 720);
  NSWindow *win = [[NSWindow alloc]
      initWithContentRect:r
                styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                           NSResizableWindowMask | NSMiniaturizableWindowMask)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [win setTitle:[_libBook displayTitle]];
  [win setMinSize:NSMakeSize(520, 400)];
  [win setDelegate:self];
  self.window = win;

  NSView *content = [win contentView];
  NSRect bar = NSMakeRect(0, r.size.height - 44, r.size.width, 44);
  NSView *topBar = [[NSView alloc] initWithFrame:bar];
  [topBar setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
  [self addBtn:topBar title:@"Contents" action:@selector(showTOC:) x:16];
  [self addBtn:topBar title:@"Prev" action:@selector(prevPage:) x:108];
  [self addBtn:topBar title:@"Next" action:@selector(nextPage:) x:184];
  [self addBtn:topBar title:@"A−" action:@selector(smaller:) x:260];
  [self addBtn:topBar title:@"A+" action:@selector(larger:) x:330];
  _themeButton = [self addBtn:topBar
                        title:[NSString stringWithFormat:@"Theme: %@", [self themeName]]
                        action:@selector(cycleTheme:)
                             x:400];
  [content addSubview:topBar];

  NSRect pv = NSMakeRect(0, 0, r.size.width, r.size.height - 44);
  _pageView = [[BookPageView alloc] initWithFrame:pv];
  [_pageView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
  [_pageView setDelegate:self];
  [content addSubview:_pageView];
}

- (NSButton *)addBtn:(NSView *)parent title:(NSString *)title action:(SEL)a x:(CGFloat)x
{
  NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x, 9, 80, 28)];
  [b setBezelStyle:NSRoundedBezelStyle];
  [b setTitle:title];
  [b setTarget:self];
  [b setAction:a];
  [parent addSubview:b];
  return b;
}

- (void)showWithZoomFromRect:(NSRect)screenRect
{
  NSLog(@"showWithZoomFromRect entry, window=%p", self.window);
  [self rebuildPaginator];
  [_pageView showSpread:_currentSpread animated:NO];
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

- (void)prevPage:(id)sender { [self goDelta:-1]; }
- (void)nextPage:(id)sender { [self goDelta:1]; }

- (void)goDelta:(NSInteger)d
{
  NSUInteger max = [_pageView spreadCount];
  if (max == 0) return;
  NSInteger target = (NSInteger)_currentSpread + d;
  if (target < 0) target = 0;
  if (target >= (NSInteger)max) target = (NSInteger)max - 1;
  _currentSpread = (NSUInteger)target;
  [_pageView showSpread:_currentSpread animated:YES];
  [self persist];
}

- (void)smaller:(id)sender
{
  _fontSize -= 2.0;
  if (_fontSize < 9.0) _fontSize = 9.0;
  [self applyFont];
  [self rebuildPaginator];
  [self persist];
}

- (void)larger:(id)sender
{
  _fontSize += 2.0;
  if (_fontSize > 42.0) _fontSize = 42.0;
  [self applyFont];
  [self rebuildPaginator];
  [self persist];
}

- (void)cycleTheme:(id)sender
{
  _theme = (_theme + 1) % 3;
  [self updateThemeColors];
  [self applyTextColor];
  [_themeButton setTitle:[NSString stringWithFormat:@"Theme: %@", [self themeName]]];
  [self rebuildPaginator];
  [self persist];
}

- (void)persist
{
  _libBook.lastSpreadIndex = _currentSpread;
  _libBook.fontSize = _fontSize;
  _libBook.theme = _theme;
  [[LibraryStore sharedStore] save];
}

#pragma mark - BookPageViewDelegate

- (void)pageViewDidRequestNext:(BookPageView *)view { [self goDelta:1]; }
- (void)pageViewDidRequestPrevious:(BookPageView *)view { [self goDelta:-1]; }

#pragma mark - TOCPanelDelegate

- (void)tocDidSelectEntry:(EPUBTOCEntry *)entry
{
  NSString *abs = [_epub absolutePathForContent:entry.contentPath];
  if (abs == nil) { [_tocPanel hide]; return; }
  NSNumber *start = [_docStart objectForKey:[abs lastPathComponent]];
  if (start)
    {
      NSUInteger page = [_pageView pageForCharacterIndex:[start unsignedIntegerValue]];
      _currentSpread = page / 2;
      [_pageView showSpread:_currentSpread animated:YES];
      [self persist];
    }
  [_tocPanel hide];
}

#pragma mark - NSWindowDelegate

- (void)windowDidResize:(NSNotification *)note
{
  [self rebuildPaginator];
}

- (void)windowWillClose:(NSNotification *)note
{
  [self persist];
  [_epub cleanupExtraction];
}

- (LibraryBook *)libraryBook
{
  return _libBook;
}

@end
