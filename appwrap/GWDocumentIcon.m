/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
 
#import "GWDocumentIcon.h"
#import "GWUtils.h"

@implementation GWDocumentIcon

+ (NSString *)createDocumentIconInResources:(NSString *)resourcesPath
                                    appName:(NSString *)appName
                           appIconFilename:(NSString *)appIconFilename
                                     mimeType:(NSString *)mimeType
                                     typeName:(NSString *)typeName
                                         size:(int)size
{
  if (!appName || !resourcesPath) return nil;

  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *sanApp = [GWUtils sanitizeFileName:appName];
  NSString *sanType = [GWUtils sanitizeFileName:typeName ? typeName : mimeType];

  NSString *docFilename = [NSString stringWithFormat:@"%@-doc-%@.png", sanApp, sanType];
  NSString *docPath = [resourcesPath stringByAppendingPathComponent:docFilename];

  // Load app icon from bundle resources
  NSImage *appIcon = nil;
  if (appIconFilename && [appIconFilename length] > 0)
    {
      NSString *appIconFull = [resourcesPath stringByAppendingPathComponent:appIconFilename];
      if ([fm fileExistsAtPath:appIconFull])
        {
          appIcon = [[NSImage alloc] initWithContentsOfFile:appIconFull];
        }
    }

  // Extract file extension from MIME type
  NSArray *extensions = [GWUtils extensionsForMIMEType:mimeType];
  NSString *extensionText = nil;
  if (extensions && [extensions count] > 0)
    {
      NSString *ext = [extensions objectAtIndex:0];
      if (ext && [ext length] > 0)
        {
          if ([ext hasPrefix:@"."])
            extensionText = [[ext substringFromIndex:1] uppercaseString];
          else
            extensionText = [ext uppercaseString];
        }
    }

  // Create combined icon using the reusable core method
  NSData *pngData = [self createCombinedIconPNGWithAppIcon:appIcon
                                            extensionText:extensionText
                                                     size:size];

  [appIcon release];

  if (!(pngData && [pngData writeToFile:docPath atomically:YES]))
    {
      NSDebugLLog(@"gwcomp", @"Failed to write document icon to %@", docPath);
      return nil;
    }

  NSImage *verify = [[NSImage alloc] initWithContentsOfFile:docPath];
  BOOL valid = (verify && [verify size].width > 0);
  [verify release];

  if (valid)
    {
      NSDebugLog(@"Document icon created and validated: %@", docPath);
      return docFilename;
    }

  NSDebugLLog(@"gwcomp", @"Removing invalid document icon: %@", docPath);
  [[NSFileManager defaultManager] removeItemAtPath:docPath error:NULL];
  return nil;
}

+ (NSData *)createCombinedIconPNGWithAppIcon:(NSImage *)appIcon
                              extensionText:(NSString *)extensionText
                                       size:(int)size
{
  NSArray *baseNames = @[@"NSDocument", @"common_document", @"common_Unknown", @"Unknown", @"page_portrait", @"NSDocumentIcon"];
  NSImage *docBase = nil;
  for (NSString *name in baseNames)
    {
      docBase = [NSImage imageNamed:name];
      if (docBase) break;
    }

  if (!docBase)
    {
      docBase = [[NSWorkspace sharedWorkspace] iconForFileType:@"public.data"];
    }

  NSImage *canvas = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
  [canvas lockFocus];

  [[NSColor clearColor] set];
  NSRectFill(NSMakeRect(0, 0, size, size));

  if (docBase)
    {
      [docBase drawInRect:NSMakeRect(0, 0, size, size)
                fromRect:NSZeroRect
               operation:NSCompositeSourceOver
                fraction:1.0];
    }
  else
    {
      NSRect r = NSMakeRect(size * 0.15, size * 0.05, size * 0.7, size * 0.9);

      [[NSColor whiteColor] setFill];
      [[NSColor darkGrayColor] setStroke];
      NSBezierPath *p = [NSBezierPath bezierPath];
      CGFloat corner = size * 0.2;
      [p moveToPoint:NSMakePoint(NSMinX(r), NSMinY(r))];
      [p lineToPoint:NSMakePoint(NSMaxX(r), NSMinY(r))];
      [p lineToPoint:NSMakePoint(NSMaxX(r), NSMaxY(r) - corner)];
      [p lineToPoint:NSMakePoint(NSMaxX(r) - corner, NSMaxY(r))];
      [p lineToPoint:NSMakePoint(NSMinX(r), NSMaxY(r))];
      [p closePath];
      [p fill];
      [p setLineWidth:size * 0.01];
      [p stroke];

      NSBezierPath *fold = [NSBezierPath bezierPath];
      [fold moveToPoint:NSMakePoint(NSMaxX(r) - corner, NSMaxY(r))];
      [fold lineToPoint:NSMakePoint(NSMaxX(r) - corner, NSMaxY(r) - corner)];
      [fold lineToPoint:NSMakePoint(NSMaxX(r), NSMaxY(r) - corner)];
      [[NSColor colorWithCalibratedWhite:0.9 alpha:1.0] setFill];
      [fold fill];
      [fold stroke];

      [[NSColor lightGrayColor] setStroke];
      [NSBezierPath setDefaultLineWidth:size * 0.01];
      for (int i = 0; i < 6; i++)
        {
          CGFloat y = NSMaxY(r) - corner - size * 0.1 - (i * size * 0.1);
          if (y < NSMinY(r) + size * 0.1) break;
          [NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(r) + size * 0.1, y)
                                    toPoint:NSMakePoint(NSMaxX(r) - size * 0.1, y)];
        }
    }

  if (appIcon)
    {
      CGFloat overlaySize = size * 0.45;
      NSRect overlayRect = NSMakeRect((size - overlaySize) / 2.0, (size - overlaySize) / 2.0, overlaySize, overlaySize);
      [appIcon drawInRect:overlayRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
    }

  if (extensionText && [extensionText length] > 0)
    {
      CGFloat overlaySize = size * 0.45;
      CGFloat overlayY = (size - overlaySize) / 2.0;
      CGFloat textBottom = overlayY - size * 0.12;

      NSFont *font = [NSFont boldSystemFontOfSize:size * 0.18];
      NSColor *textColor = [NSColor colorWithCalibratedWhite:0.25 alpha:1.0];
      NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName, textColor, NSForegroundColorAttributeName, nil];

      NSSize textSize = [extensionText sizeWithAttributes:attrs];
      NSPoint textPoint = NSMakePoint((size - textSize.width) / 2.0, textBottom - (textSize.height * 0.5));
      [extensionText drawAtPoint:textPoint withAttributes:attrs];
    }

  NSData *pngData = nil;
  NSData *tiffData = [canvas TIFFRepresentation];
  if (tiffData)
    {
      NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiffData];
      if (rep)
        pngData = [rep representationUsingType:NSPNGFileType properties:nil];
    }
  [canvas unlockFocus];
  [canvas release];

  return pngData;
}

@end
