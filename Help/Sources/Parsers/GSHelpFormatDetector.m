/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpFormatDetector.h"

NSString * const GSHelpFormatMarkdown = @"GSHelpFormatMarkdown";
NSString * const GSHelpFormatMan = @"GSHelpFormatMan";
NSString * const GSHelpFormatGSDoc = @"GSHelpFormatGSDoc";
NSString * const GSHelpFormatText = @"GSHelpFormatText";

@implementation GSHelpFormatDetector

+ (BOOL)isKnownFormat:(NSString *)format
{
  return [format isEqualToString: GSHelpFormatMarkdown]
      || [format isEqualToString: GSHelpFormatMan]
      || [format isEqualToString: GSHelpFormatGSDoc]
      || [format isEqualToString: GSHelpFormatText];
}

+ (nullable NSString *)canonicalHint:(NSString *)hint
{
  if ([self isKnownFormat: hint])
    return hint;

  /* Short-name aliases; built per call because it is tiny and this
   * keeps the class free of shared mutable state. */
  NSDictionary<NSString *, NSString *> *names =
    @{ @"markdown": GSHelpFormatMarkdown,
       @"man": GSHelpFormatMan,
       @"gsdoc": GSHelpFormatGSDoc,
       @"text": GSHelpFormatText };
  return names[[hint lowercaseString]];
}

/* Walks the extension chain of a path component, so "foo.1.gz" is
 * checked as ".gz" then ".1". Returns nil when no known format
 * extension is found. */
+ (nullable NSString *)formatFromComponent:(NSString *)component
{
  if (component.length == 0)
    return nil;

  NSString *ext = component.pathExtension;
  if (ext.length == 0 || [component isEqualToString: ext])
    return nil;

  if ([ext caseInsensitiveCompare: @"md"] == NSOrderedSame
      || [ext caseInsensitiveCompare: @"markdown"] == NSOrderedSame)
    return GSHelpFormatMarkdown;
  if ([ext caseInsensitiveCompare: @"gsdoc"] == NSOrderedSame)
    return GSHelpFormatGSDoc;
  if ([ext caseInsensitiveCompare: @"txt"] == NSOrderedSame
      || [ext caseInsensitiveCompare: @"text"] == NSOrderedSame)
    return GSHelpFormatText;

  /* Man section: digits optionally followed by letters/digits, e.g.
   * 1, 3x, 3ssl; or a compressed page whose inner component carries
   * the section. */
  NSRegularExpression *section = [NSRegularExpression
      regularExpressionWithPattern: @"^\\d\\w*$"
                           options: 0 error: NULL];
  if ([section numberOfMatchesInString: ext options: 0
                                 range: NSMakeRange(0, ext.length)] == 1)
    return GSHelpFormatMan;

  if ([ext caseInsensitiveCompare: @"gz"] == NSOrderedSame
      || [ext caseInsensitiveCompare: @"bz2"] == NSOrderedSame
      || [ext caseInsensitiveCompare: @"xz"] == NSOrderedSame)
    {
      NSString *stem = [component substringToIndex:
                          component.length - ext.length - 1];
      /* Only a man section stem makes sense for compressed docs. */
      NSString *inner = [self formatFromComponent: stem];
      if ([inner isEqualToString: GSHelpFormatMan])
        return GSHelpFormatMan;
    }

  return nil;
}

+ (NSString *)formatFromExtensionOfURL:(NSURL *)url
{
  return [self formatFromComponent: url.lastPathComponent];
}

/* Compression magics map to man because compressed documentation
 * sources are man pages in practice (SPEC 20). */
+ (nullable NSString *)formatFromMagic:(NSData *)data
{
  const unsigned char *b = data.bytes;
  NSUInteger len = data.length;

  if (len >= 2 && b[0] == 0x1f && b[1] == 0x8b)
    return GSHelpFormatMan;
  if (len >= 3 && b[0] == 'B' && b[1] == 'Z' && b[2] == 'h')
    return GSHelpFormatMan;
  if (len >= 6 && b[0] == 0xfd && memcmp(b + 1, "7zXZ\x00", 5) == 0)
    return GSHelpFormatMan;

  return nil;
}

+ (nullable NSString *)formatFromContent:(NSData *)data
{
  NSString *magic = [self formatFromMagic: data];
  if (magic != nil)
    return magic;

  /* Decode only the head; strict UTF-8 first, Latin-1 as the lossless
   * byte-preserving fallback for sniffing purposes. */
  NSData *head = data.length > 512
      ? [data subdataWithRange: NSMakeRange(0, 512)] : data;
  NSString *text = [[NSString alloc] initWithData: head
                                         encoding: NSUTF8StringEncoding];
  if (text == nil)
    text = [[NSString alloc] initWithData: head
                                 encoding: NSISOLatin1StringEncoding];
  if (text == nil)
    return nil;

  NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];

  /* roff source: .TH title line or the classic roff comment line. */
  if ([trimmed hasPrefix: @".TH"]
      || [trimmed hasPrefix: @"'\\"]
      || [trimmed hasPrefix: @"' "])
    return GSHelpFormatMan;

  if ([trimmed hasPrefix: @"<?xml"]
      && [text rangeOfString: @"<gsdoc"].location != NSNotFound)
    return GSHelpFormatGSDoc;

  /* Markdown ATX heading within the first few non-blank lines. */
  NSArray<NSString *> *lines =
      [text componentsSeparatedByCharactersInSet:
              [NSCharacterSet newlineCharacterSet]];
  NSUInteger seen = 0;
  NSRegularExpression *atx = [NSRegularExpression
      regularExpressionWithPattern: @"^#{1,6}\\s+\\S"
                           options: 0 error: NULL];
  for (NSString *line in lines)
    {
      if (line.length == 0)
        continue;
      if (++seen > 10)
        break;
      if ([atx numberOfMatchesInString: line options: 0
                                 range: NSMakeRange(0, line.length)] > 0)
        return GSHelpFormatMarkdown;
    }

  return nil;
}

+ (NSString *)detectFormatForURL:(NSURL *)url
                      formatHint:(NSString *)hint
                  bundleMetadata:(NSDictionary<NSString *, id> *)plist
{
  NSString *canon = [self canonicalHint: hint];
  if (canon != nil)
    return canon;

  /* Help-bundle metadata hook (SPEC 10 priority 2): a Help.plist may
   * pin formats per file name via its FileFormats dictionary. */
  NSDictionary *formats = plist[@"FileFormats"];
  if ([formats isKindOfClass: [NSDictionary class]])
    {
      NSString *byName = formats[url.lastPathComponent];
      if ([self isKnownFormat: byName])
        return byName;
    }

  if (url.isFileURL)
    {
      NSString *byExt = [self formatFromExtensionOfURL: url];
      if (byExt != nil)
        return byExt;

      NSData *data = [NSData dataWithContentsOfURL: url
                                           options: NSDataReadingMappedIfSafe
                                             error: NULL];
      if (data.length > 0)
        {
          NSString *byContent = [self formatFromContent: data];
          if (byContent != nil)
            return byContent;
        }
    }

  return GSHelpFormatText;
}

+ (NSString *)detectFormatForURL:(NSURL *)url
                      formatHint:(NSString *)hint
{
  return [self detectFormatForURL: url formatHint: hint
                   bundleMetadata: nil];
}

+ (NSString *)detectFormatForURL:(NSURL *)url
{
  return [self detectFormatForURL: url formatHint: nil
                   bundleMetadata: nil];
}

@end
