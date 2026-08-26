/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "BookPageView.h"
#import "EPUBPaginator.h"
#import "EPUBPageRenderer.h"
#import "GLPageTurnView.h"
#include <math.h>

@interface BookPageView ()
@property (nonatomic, strong) NSAttributedString *attrString;
@property (nonatomic, strong) EPUBPaginator *paginator;
@property (nonatomic, strong) EPUBPageRenderer *renderer;
@property (nonatomic, assign) BOOL usesGL;
@property (nonatomic, strong) GLPageTurnView *glView;
@property (nonatomic, assign) NSUInteger currentSpread;
@property (nonatomic, assign) NSUInteger pageCount;
@property (nonatomic, strong) NSBitmapImageRep *leftImage;
@property (nonatomic, strong) NSBitmapImageRep *rightImage;
@end

@implementation BookPageView

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self)
    {
      _usesGL = NO; /* DIAGNOSTIC: force software renderer to isolate GL issue */
      if (_usesGL)
        {
          _glView = [[GLPageTurnView alloc] initWithFrame:[self bounds]];
          [_glView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
          [self addSubview:_glView];
        }
      _backgroundColor = [NSColor whiteColor];
      _textColor = [NSColor blackColor];
    }
  return self;
}

- (void)configureWithAttributedString:(NSAttributedString *)attr
                            paginator:(EPUBPaginator *)pag
                             renderer:(EPUBPageRenderer *)rend
{
  self.attrString = attr;
  self.paginator = pag;
  self.renderer = rend;
  self.pageCount = [pag pageCount];
  self.currentSpread = 0;
}

- (NSUInteger)spreadCount
{
  return (self.pageCount + 1) / 2;
}

- (BOOL)canGoNext
{
  return self.currentSpread + 1 < [self spreadCount];
}

- (BOOL)canGoPrevious
{
  return self.currentSpread > 0;
}

- (NSSize)contentSize
{
  NSRect b = [self bounds];
  CGFloat w = b.size.width / 2.0;
  CGFloat h = b.size.height;
  if (w < 10) w = 450;
  if (h < 10) h = 650;
  return NSMakeSize(MAX(50.0, w - 64.0), MAX(50.0, h - 64.0));
}

- (NSBitmapImageRep *)renderPage:(NSUInteger)idx
{
  if (idx >= self.pageCount)
    return [self blankImage];
  NSRange r = [self.paginator rangeForPage:idx];
  return [self.renderer imageForRange:r
                    ofAttributedString:self.attrString
                              pageSize:[self contentSize]
                       backgroundColor:self.backgroundColor
                             textColor:self.textColor];
}

- (NSBitmapImageRep *)blankImage
{
  NSSize s = [self contentSize];
  return [self.renderer imageForRange:NSMakeRange(0, 0)
                    ofAttributedString:nil
                              pageSize:s
                       backgroundColor:self.backgroundColor
                             textColor:self.textColor];
}

- (void)setBackgroundColor:(NSColor *)backgroundColor
{
  _backgroundColor = backgroundColor;
  [self refreshStatic];
}

- (void)setThemeTextColor:(NSColor *)textColor
{
  _textColor = textColor;
  [self refreshStatic];
}

- (void)refreshStatic
{
  if (self.attrString == nil) return;
  [self showSpread:self.currentSpread animated:NO];
}

- (void)showSpread:(NSUInteger)spread animated:(BOOL)animated
{
  if (self.attrString == nil) return;
  NSUInteger maxSpread = [self spreadCount];
  if (spread >= maxSpread) spread = maxSpread - 1;
  if (maxSpread == 0) return;

  self.currentSpread = spread;
  self.leftImage = [self renderPage:spread * 2];
  self.rightImage = [self renderPage:spread * 2 + 1];
  if (self.usesGL && self.glView)
    [self.glView displayLeft:self.leftImage right:self.rightImage];
  else
    [self setNeedsDisplay:YES];
}

- (void)next
{
  if ([self canGoNext])
    [self showSpread:self.currentSpread + 1 animated:YES];
}

- (void)previous
{
  if ([self canGoPrevious])
    [self showSpread:self.currentSpread - 1 animated:YES];
}

- (BOOL)acceptsFirstResponder
{
  return YES;
}

// WHY mouseDown (not mouseUp): the reader is a static page with no text
// selection, so an immediate flip on press feels responsive and avoids the
// drag-vs-click ambiguity. The leftmost and rightmost quarters of the view flip
// back and forward respectively; the middle half is left for future gestures.
- (void)mouseDown:(NSEvent *)event
{
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  NSRect b = [self bounds];
  CGFloat quarter = b.size.width / 4.0;
  if (p.x < quarter)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestPrevious:)])
        [_delegate pageViewDidRequestPrevious:self];
      else
        [self previous];
    }
  else if (p.x > b.size.width - quarter)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestNext:)])
        [_delegate pageViewDidRequestNext:self];
      else
        [self next];
    }
}

- (void)keyDown:(NSEvent *)event
{
  NSString *s = [event charactersIgnoringModifiers];
  if ([s length] == 0) return;
  unichar c = [s characterAtIndex:0];
  if (c == NSRightArrowFunctionKey || c == ' ' || c == NSCarriageReturnCharacter)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestNext:)])
        [_delegate pageViewDidRequestNext:self];
      else
        [self next];
    }
  else if (c == NSLeftArrowFunctionKey)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestPrevious:)])
        [_delegate pageViewDidRequestPrevious:self];
      else
        [self previous];
    }
}

- (NSUInteger)pageForCharacterIndex:(NSUInteger)idx
{
  if (self.paginator == nil) return 0;
  return [self.paginator pageForCharacterIndex:idx];
}

- (void)drawRect:(NSRect)rect
{
  if (self.usesGL) return;
  NSRect b = [self bounds];
  [[self.backgroundColor shadowWithLevel:0.7] set];
  NSRectFill(b);

  NSRect leftR = NSMakeRect(0, 0, b.size.width / 2.0, b.size.height);
  NSRect rightR = NSMakeRect(b.size.width / 2.0, 0, b.size.width / 2.0, b.size.height);

  [self.leftImage drawInRect:leftR
                    fromRect:NSZeroRect
                   operation:NSCompositeSourceOver
                    fraction:1.0
               respectFlipped:NO
                    hints:nil];
  [self.rightImage drawInRect:rightR
                     fromRect:NSZeroRect
                    operation:NSCompositeSourceOver
                     fraction:1.0
               respectFlipped:NO
                    hints:nil];

  NSRect spine = NSMakeRect(b.size.width / 2.0 - 6, 0, 12, b.size.height);
  NSGradient *g = [[NSGradient alloc]
      initWithStartingColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.0]
                endingColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.5]];
  [g drawInRect:spine angle:0.0];
}

@end
