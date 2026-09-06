/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "GLPageTurnView.h"
#import <GL/gl.h>
#include <math.h>

@interface GLPageTurnView ()
{
  GLuint _texLeft;
  GLuint _texRight;
  BOOL _hasLeft;
  BOOL _hasRight;
  CGFloat _angle;
  NSTimer *_turnTimer;
  void (^_turnCompletion)(void);
}
@end

@implementation GLPageTurnView

+ (BOOL)glSupported
{
  NSOpenGLPixelFormat *pf = [NSOpenGLView defaultPixelFormat];
  if (pf == nil) return NO;
  NSOpenGLContext *ctx = [[NSOpenGLContext alloc] initWithFormat:pf shareContext:nil];
  return (ctx != nil);
}

- (void)dealloc
{
  [self deleteTex:&_texLeft];
  [self deleteTex:&_texRight];
}

- (void)deleteTex:(GLuint *)t
{
  if (*t != 0)
    {
      glDeleteTextures(1, t);
      *t = 0;
    }
}

- (void)prepareOpenGL
{
  [super prepareOpenGL];
  glDisable(GL_DEPTH_TEST);
  glEnable(GL_TEXTURE_2D);
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
  glClearColor(0.12, 0.10, 0.08, 1.0);
}

- (GLuint)textureFromBitmapRep:(NSBitmapImageRep *)rep
{
  if (rep == nil) return 0;
  int w = (int)[rep pixelsWide];
  int h = (int)[rep pixelsHigh];
  if (w < 1 || h < 1) return 0;
  if ([rep bitsPerSample] != 8) return 0;

  unsigned char *src = (unsigned char *)[rep bitmapData];
  int srcBytesPerRow = (int)[rep bytesPerRow];
  if (src == NULL || srcBytesPerRow < 1) return 0;

  int samples = (int)[rep samplesPerPixel];
  unsigned char *data = (unsigned char *)malloc((size_t)w * (size_t)h * 4);
  if (data == NULL) return 0;

   // WHY flip rows: the rep produced by EPUBPageRenderer (via a flipped
   // offscreen view + initWithFocusedViewRect:) is top-down (row 0 at the top
   // of the page). OpenGL's texture origin is bottom-up, so copy each source
   // row to its vertically mirrored destination row.
   size_t rowBytes = (size_t)w * 4;
   for (int y = 0; y < h; y++)
     {
       unsigned char *srcRow = src + (size_t)y * (size_t)srcBytesPerRow;
       unsigned char *dst = data + (size_t)(h - 1 - y) * rowBytes;
      if (samples >= 3)
        memcpy(dst, srcRow, rowBytes);
      else
        {
          // Grayscale/alpha-only reps are unexpected here; emit white.
          memset(dst, 255, rowBytes);
        }
    }

  GLuint tex = 0;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, data);
  free(data);
  return tex;
}

- (void)displayLeft:(NSBitmapImageRep *)left right:(NSBitmapImageRep *)right
{
  [self deleteTex:&_texLeft];
  [self deleteTex:&_texRight];
  _texLeft = [self textureFromBitmapRep:left];
  _texRight = [self textureFromBitmapRep:right];
  _hasLeft = (_texLeft != 0);
  _hasRight = (_texRight != 0);
  _angle = 0.0;
  [self setNeedsDisplay:YES];
}

// Animate a quick flip of the spread around the vertical spine, then hand back
// to the caller so it can reveal the (already updated) text views underneath.
- (void)turnWithCompletion:(void (^)(void))block
{
  if (block) _turnCompletion = [block copy];
  _angle = 0.0;
  if (_turnTimer != nil) { [_turnTimer invalidate]; _turnTimer = nil; }
  _turnTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                               target:self
                                             selector:@selector(_turnTick:)
                                             userInfo:nil
                                              repeats:YES];
}

- (void)_turnTick:(NSTimer *)t
{
  _angle += 4.0;
  if (_angle >= 90.0)
    {
      _angle = 90.0;
      [_turnTimer invalidate];
      _turnTimer = nil;
      [self setNeedsDisplay:YES];
      if (_turnCompletion != nil)
        {
          void (^b)(void) = _turnCompletion;
          _turnCompletion = nil;
          b();
        }
      return;
    }
  [self setNeedsDisplay:YES];
}

- (void)drawQuad:(GLuint)tex x0:(GLfloat)x0 x1:(GLfloat)x1 shade:(GLfloat)sh
{
  if (tex == 0) return;
  glBindTexture(GL_TEXTURE_2D, tex);
  glColor3f(sh, sh, sh);
  glBegin(GL_QUADS);
  glTexCoord2f(0.0, 0.0); glVertex2f(x0, -1.0);
  glTexCoord2f(1.0, 0.0); glVertex2f(x1, -1.0);
  glTexCoord2f(1.0, 1.0); glVertex2f(x1, 1.0);
  glTexCoord2f(0.0, 1.0); glVertex2f(x0, 1.0);
  glEnd();
}

- (void)drawRect:(NSRect)rect
{
  [[self openGLContext] makeCurrentContext];

  NSRect b = [self bounds];
  glViewport(0, 0, (GLsizei)b.size.width, (GLsizei)b.size.height);
  glClear(GL_COLOR_BUFFER_BIT);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  glOrtho(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity();

  if (!_hasRight && !_hasLeft)
    {
      [[self openGLContext] flushBuffer];
      return;
    }

  glRotatef(_angle, 0.0, 1.0, 0.0);
  [self drawQuad:_texLeft x0:-1.0 x1:0.0 shade:1.0];
  [self drawQuad:_texRight x0:0.0 x1:1.0 shade:1.0];

  [[self openGLContext] flushBuffer];
}

@end
