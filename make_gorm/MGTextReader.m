/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MGTextReader.h"
#import "MGTypes.h"

#import <Foundation/Foundation.h>
#import <GNUstepBase/GNUstep.h>

/*
 * Parser state for the text format.
 * Uses a line-based approach with a current index into lines array.
 */
@interface MGTextReader ()
{
@private
  NSArray   *_lines;   /* Lines of the text (NSString) */
  NSUInteger _idx;     /* Current line index */
  NSUInteger _lineno;  /* Current line number (1-based) */
}
@end

@implementation MGTextReader

/* ============================================================
 *  Utility methods
 * ============================================================ */

/* Return current line, or nil */
- (NSString *)_currentLine
{
  if (_idx >= [_lines count])
    return nil;
  return [_lines objectAtIndex:_idx];
}

/* Advance to next line */
- (void)_advanceLine
{
  _idx++;
  _lineno++;
}

/* Skip blank lines and return first non-blank line */
- (NSString *)_skipBlankLines
{
  NSString *line;
  while ((line = [self _currentLine]) != nil)
    {
      NSString *trimmed = [line stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
      if ([trimmed length] > 0)
        return line;
      [self _advanceLine];
    }
  return nil;
}

/* Convert hex string to NSData */
- (NSData *)_hexToData:(NSString *)hex
{
  NSMutableData *data = [NSMutableData data];
  NSUInteger len = [hex length] / 2;
  for (NSUInteger i = 0; i < len; i++)
    {
      NSString *byteStr = [hex substringWithRange:NSMakeRange(i * 2, 2)];
      NSScanner *sc = [NSScanner scannerWithString:byteStr];
      unsigned int val = 0;
      if ([sc scanHexInt:&val])
        {
          uint8_t byte = (uint8_t)val;
          [data appendBytes:&byte length:1];
        }
    }
  return data;
}

/* Report an error */
- (BOOL)_error:(NSError **)error
      message:(NSString *)fmt, ...
{
  if (error != nil)
    {
      va_list args;
      va_start(args, fmt);
      NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
      va_end(args);
      NSString *fullMsg = [NSString stringWithFormat:
        @"Line %lu: %@", (unsigned long)_lineno, msg];
      *error = [NSError errorWithDomain:@"MGTextReaderErrorDomain"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: fullMsg}];
      RELEASE(msg);
    }
  return NO;
}

/* ============================================================
 *  Value parsing
 * ============================================================ */

/*
 * Parse a quoted string value.
 * line: trimmed line starting at or after the opening quote.
 * Returns the parsed value and sets consumed to the number of characters used.
 */
- (id)_parseStringOnLine:(NSString *)line
                consumed:(NSUInteger *)consumed
{
  NSUInteger len = [line length];
  NSMutableString *str = [NSMutableString string];
  BOOL inEscape = NO;
  NSUInteger i;

  /* Find opening quote */
  for (i = 0; i < len; i++)
    {
      if ([line characterAtIndex:i] == '"')
        break;
    }
  if (i >= len)
    return nil;

  /* Skip opening quote */
  for (i = i + 1; i < len; i++)
    {
      unichar ch = [line characterAtIndex:i];
      if (inEscape)
        {
          switch (ch)
            {
              case 'n':  [str appendString:@"\n"]; break;
              case 't':  [str appendString:@"\t"]; break;
              case 'r':  [str appendString:@"\r"]; break;
              case '\\': [str appendString:@"\\"]; break;
              case '"':  [str appendString:@"\""]; break;
              default:   [str appendFormat:@"%C", ch]; break;
            }
          inEscape = NO;
        }
      else if (ch == '\\')
        {
          inEscape = YES;
        }
      else if (ch == '"')
        {
          /* End of string */
          i++;
          break;
        }
      else
        {
          [str appendFormat:@"%C", ch];
        }
    }

  if (consumed != NULL)
    *consumed = i;

  return str;
}

/*
 * Parse a value from a line, starting at the given position.
 * Returns the parsed value and sets *endPos to the next position to read.
 */
- (id)_parseValueOnLine:(NSString *)line
                atPos:(NSUInteger)pos
               endPos:(NSUInteger *)endPos
{
  if (line == nil || pos >= [line length])
    return nil;

  /* Skip whitespace */
  while (pos < [line length]
         && [[NSCharacterSet whitespaceCharacterSet]
           characterIsMember:[line characterAtIndex:pos]])
    {
      pos++;
    }

  if (pos >= [line length])
    return nil;

  unichar ch = [line characterAtIndex:pos];

  /* Quoted string */
  if (ch == '"')
    {
      NSUInteger consumed = 0;
      id result = [self _parseStringOnLine:line consumed:&consumed];
      if (endPos != NULL)
        *endPos = consumed;
      return result;
    }

  /* Reference: @<number> */
  if (ch == '@')
    {
      pos++; /* skip @ */
      int refId = 0;
      while (pos < [line length]
             && [[NSCharacterSet decimalDigitCharacterSet]
               characterIsMember:[line characterAtIndex:pos]])
        {
          refId = refId * 10 + ([line characterAtIndex:pos] - '0');
          pos++;
        }
      if (endPos != NULL)
        *endPos = pos;
      return [NSString stringWithFormat:@"@%d", refId];
    }

  /* Boolean or null or number */
  if ([[NSCharacterSet letterCharacterSet] characterIsMember:ch]
      || ch == '-' || ch == '+'
      || [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:ch]
      || ch == '.')
    {
      NSUInteger start = pos;
      while (pos < [line length]
             && ![[NSCharacterSet whitespaceCharacterSet]
               characterIsMember:[line characterAtIndex:pos]]
             && [line characterAtIndex:pos] != ';'
             && [line characterAtIndex:pos] != ','
             && [line characterAtIndex:pos] != ']'
             && [line characterAtIndex:pos] != '}')
        {
          pos++;
        }
      NSString *token = [line substringWithRange:NSMakeRange(start, pos - start)];

      if (endPos != NULL)
        *endPos = pos;

      if ([token isEqualToString:@"true"])
        return [[[MGBoolBox alloc] initWithBool:YES] autorelease];
      if ([token isEqualToString:@"false"])
        return [[[MGBoolBox alloc] initWithBool:NO] autorelease];
      if ([token isEqualToString:@"null"])
        return [NSNull null];

      /* Try number parsing */
      NSScanner *scanner = [NSScanner scannerWithString:token];
      if ([token rangeOfString:@"."].location != NSNotFound
          || [token rangeOfString:@"e"].location != NSNotFound
          || [token rangeOfString:@"E"].location != NSNotFound)
        {
          double dval;
          if ([scanner scanDouble:&dval] && [scanner isAtEnd])
            return [NSNumber numberWithDouble:dval];
        }
      else
        {
          long long ival;
          if ([scanner scanLongLong:&ival] && [scanner isAtEnd])
            return [NSNumber numberWithLongLong:ival];
        }

      /* Fallback: return as string */
      return token;
    }

  /* Array: parse recursively */
  if (ch == '[')
    {
      return [self _parseArrayFromLine:line atPos:pos endPos:endPos];
    }

  /* Dictionary: parse recursively */
  if (ch == '{')
    {
      return [self _parseDictFromLine:line atPos:pos endPos:endPos];
    }

  /* Data block indicator */
  if (ch == '<')
    {
      /* Check if this is <data> */
      if (pos + 5 < [line length]
          && [[line substringWithRange:NSMakeRange(pos, 5)]
            isEqualToString:@"<data"])
        {
          return [self _parseDataBlock];
        }

      /* Otherwise it might be a struct value like {10,20,80,24} */
      NSUInteger close = [line rangeOfString:@">"
                                     options:0
                                       range:NSMakeRange(pos, [line length] - pos)].location;
      if (close != NSNotFound)
        {
          NSString *inner = [line substringWithRange:NSMakeRange(pos, close - pos + 1)];
          if (endPos != NULL)
            *endPos = close + 1;
          return inner;
        }
    }

  return nil;
}

/*
 * Parse an array value: [val1, val2, ...]
 */
- (id)_parseArrayFromLine:(NSString *)line
                     atPos:(NSUInteger)pos
                    endPos:(NSUInteger *)endPos
{
  NSMutableArray *result = [NSMutableArray array];

  /* Find opening bracket */
  while (pos < [line length] && [line characterAtIndex:pos] != '[')
    pos++;
  if (pos >= [line length])
    return result;

  pos++; /* Skip '[' */

  while (pos < [line length])
    {
      /* Skip whitespace and commas */
      while (pos < [line length]
             && ([[NSCharacterSet whitespaceCharacterSet]
                   characterIsMember:[line characterAtIndex:pos]]
                 || [line characterAtIndex:pos] == ','))
        pos++;

      if (pos >= [line length] || [line characterAtIndex:pos] == ']')
        break;

      NSUInteger valEnd = pos;
      id val = [self _parseValueOnLine:line atPos:pos endPos:&valEnd];
      if (val != nil)
        {
          [result addObject:val];
          pos = valEnd;
        }
      else
        {
          pos++;
        }
    }

  /* Skip closing bracket */
  if (pos < [line length] && [line characterAtIndex:pos] == ']')
    pos++;

  /* If we haven't found the closing bracket yet, it might be on the next line */
  if (pos >= [line length] || [line characterAtIndex:pos - 1] != ']')
    {
      [self _advanceLine];
      NSString *nextLine = [self _currentLine];
      while (nextLine != nil)
        {
          NSString *trimmed = [nextLine stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
          if ([trimmed hasPrefix:@"]"])
            {
              break;
            }
          else if ([trimmed length] > 0 && ![trimmed hasPrefix:@","])
            {
              /* Parse value from this line */
              NSUInteger vEnd = 0;
              id val = [self _parseValueOnLine:trimmed
                                        atPos:0
                                       endPos:&vEnd];
              if (val != nil)
                [result addObject:val];
            }
          [self _advanceLine];
          nextLine = [self _currentLine];
        }
    }

  if (endPos != NULL)
    *endPos = pos;

  return result;
}

/*
 * Parse a dictionary value: {key = value; key2 = value2;}
 * (dictionary may span multiple lines - the parser handles it line by line)
 */
- (id)_parseDictFromLine:(NSString *)line
                    atPos:(NSUInteger)pos
                   endPos:(NSUInteger *)endPos
{
  NSMutableDictionary *result = [NSMutableDictionary dictionary];

  /* Find opening brace */
  while (pos < [line length] && [line characterAtIndex:pos] != '{')
    pos++;
  if (pos >= [line length])
    return result;

  pos++; /* Skip '{' */

  while (pos < [line length])
    {
      /* Skip whitespace and semicolons */
      while (pos < [line length]
             && ([[NSCharacterSet whitespaceCharacterSet]
                   characterIsMember:[line characterAtIndex:pos]]
                 || [line characterAtIndex:pos] == ';'))
        pos++;

      if (pos >= [line length] || [line characterAtIndex:pos] == '}')
        break;

      /* Parse key */
      NSUInteger keyStart = pos;
      while (pos < [line length]
             && [line characterAtIndex:pos] != '='
             && ![[NSCharacterSet whitespaceCharacterSet]
                   characterIsMember:[line characterAtIndex:pos]])
        {
          pos++;
        }
      NSString *key = [line substringWithRange:NSMakeRange(keyStart, pos - keyStart)];

      /* Skip whitespace and '=' */
      while (pos < [line length]
             && ([line characterAtIndex:pos] == '='
                 || [[NSCharacterSet whitespaceCharacterSet]
                       characterIsMember:[line characterAtIndex:pos]]))
        {
          pos++;
        }

      /* Parse value */
      NSUInteger valEnd = pos;
      id val = [self _parseValueOnLine:line atPos:pos endPos:&valEnd];
      if (val != nil)
        {
          [result setObject:val forKey:key];
          pos = valEnd;
        }
      else
        {
          pos++;
        }
    }

  /* If we haven't found the closing brace yet, continue on next lines */
  if (pos >= [line length] || [line characterAtIndex:pos - 1] != '}')
    {
      [self _advanceLine];
      NSString *nextLine = [self _currentLine];
      while (nextLine != nil)
        {
          NSString *trimmed = [nextLine stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
          if ([trimmed hasPrefix:@"}"])
            {
              break;
            }
          else if ([trimmed length] > 0)
            {
              /* Look for "key = value;" pattern */
              NSScanner *scanner = [NSScanner scannerWithString:trimmed];
              NSString *key = nil;
              [scanner scanUpToString:@"=" intoString:&key];
              if (key != nil)
                {
                  key = [key stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                  [scanner scanString:@"=" intoString:NULL];
                  /* Parse value */
                  NSUInteger vEnd = 0;
                  id val = [self _parseValueOnLine:trimmed
                                            atPos:[scanner scanLocation]
                                           endPos:&vEnd];
                  if (val != nil)
                    [result setObject:val forKey:key];
                }
            }
          [self _advanceLine];
          nextLine = [self _currentLine];
        }
    }

  if (endPos != NULL)
    *endPos = pos;

  return result;
}

/*
 * Parse data block from inline string (the opening tag is on this line).
 */
- (id)_parseDataBlockFromString:(NSString *)startLine
{
  /* Check if the </data> tag is on the same line */
  NSRange endRange = [startLine rangeOfString:@"</data>"];
  if (endRange.location != NSNotFound)
    {
      NSString *hexPart = [startLine substringFromIndex:6]; /* skip <data> */
      hexPart = [hexPart substringToIndex:endRange.location - 6];
      hexPart = [hexPart stringByReplacingOccurrencesOfString:@" "
                                                   withString:@""];
      hexPart = [hexPart stringByReplacingOccurrencesOfString:@"\t"
                                                   withString:@""];
      return [self _hexToData:hexPart];
    }

  /* Multi-line: read lines from subsequent lines */
  [self _advanceLine];
  return [self _parseDataBlock];
}

/*
 * Parse a <data> block.
 * Assumes current line has the opening <data> tag.
 * Collects hex lines until closing </data> tag.
 * After </data>, consumes optional semicolon and whitespace.
 */
- (id)_parseDataBlock
{
  NSMutableData *data = [NSMutableData data];

  /* Skip opening <data> tag line if we're on it */
  NSString *cl = [self _currentLine];
  if (cl) {
    NSString *trimmed = [cl stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceCharacterSet]];
    if ([trimmed hasPrefix:@"<data>"])
      [self _advanceLine];
  }

  /* Collect hex lines */
  NSString *line;
  while ((line = [self _currentLine]) != nil)
    {
      NSString *trimmed = [line stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];

      if ([trimmed hasPrefix:@"</data>"])
        {
          [self _advanceLine];
          /* Consume optional semicolon after </data> */
          NSString *after = [self _currentLine];
          if (after) {
            NSString *at = [after stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceCharacterSet]];
            if ([at hasPrefix:@";"])
              [self _advanceLine];
          }
          return data;
        }

      /* Remove any spaces or newlines */
      trimmed = [trimmed stringByReplacingOccurrencesOfString:@" "
                                                    withString:@""];
      trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\t"
                                                    withString:@""];

      if ([trimmed length] > 0)
        {
          NSUInteger len = [trimmed length] / 2;
          for (NSUInteger i = 0; i < len; i++)
            {
              NSString *byteStr = [trimmed substringWithRange:
                NSMakeRange(i * 2, 2)];
              NSScanner *scanner = [NSScanner scannerWithString:byteStr];
              unsigned int byteVal = 0;
              if ([scanner scanHexInt:&byteVal])
                {
                  uint8_t byte = (uint8_t)byteVal;
                  [data appendBytes:&byte length:1];
                }
            }
        }

      [self _advanceLine];
    }

  return data;
}

/* ============================================================
 *  Metadata parsing
 * ============================================================ */

/*
 * Parse the metadata section:
 * metadata
 * {
 *     archiveVersion = 7;
 *     coderVersion = 2;
 * }
 */
- (BOOL)_parseMetadataInto:(MGArchive *)archive
                    error:(NSError **)error
{
  /* Skip blank lines */
  NSString *line = [self _skipBlankLines];
  if (line == nil)
    return YES; /* No metadata, that's OK */

  NSString *trimmed = [line stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceCharacterSet]];

  if (![trimmed isEqualToString:@"metadata"])
    return YES; /* Not metadata, rewind */

  [self _advanceLine];

  /* Expect opening brace */
  line = [self _skipBlankLines];
  if (line == nil)
    return [self _error:error message:@"Unexpected end of file in metadata"];

  trimmed = [line stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceCharacterSet]];
  if (![trimmed isEqualToString:@"{"])
    return [self _error:error
                message:@"Expected '{' in metadata, got '%@'", trimmed];

  [self _advanceLine];

  /* Parse property lines until closing brace */
  while ((line = [self _currentLine]) != nil)
    {
      trimmed = [line stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];

      if ([trimmed isEqualToString:@"}"])
        {
          [self _advanceLine];
          return YES;
        }

      if ([trimmed length] == 0)
        {
          [self _advanceLine];
          continue;
        }

      /* Parse key = value; */
      NSScanner *scanner = [NSScanner scannerWithString:trimmed];
      NSString *key = nil;
      [scanner scanUpToString:@"=" intoString:&key];
      if (key == nil)
        {
          [self _advanceLine];
          continue;
        }

      key = [key stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];

      [scanner scanString:@"=" intoString:NULL];

      /* Read value */
      NSString *valStr = nil;
      [scanner scanUpToString:@";" intoString:&valStr];
      if (valStr != nil)
        {
          valStr = [valStr stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        }

      if ([key isEqualToString:@"archiveVersion"])
        {
          archive.systemVersion = (unsigned)[valStr intValue];
        }
      else if ([key isEqualToString:@"coderVersion"])
        {
          /* Not stored, but parse it */
        }

      [self _advanceLine];
    }

  return [self _error:error message:@"Unterminated metadata section"];
}

/* ============================================================
 *  Object parsing
 * ============================================================ */

/*
 * Parse a property value, which may span multiple lines.
 * Returns the parsed value.
 */
- (id)_parsePropertyValueFromLine:(NSString *)trimmedLine
{
  /* Check for data block */
  if ([trimmedLine hasPrefix:@"<data>"])
    {
      return [self _parseDataBlock];
    }

  /* Check for array */
  if ([trimmedLine hasPrefix:@"["])
    {
      NSUInteger endPos = 0;
      return [self _parseArrayFromLine:trimmedLine atPos:0 endPos:&endPos];
    }

  /* Check for dictionary */
  if ([trimmedLine hasPrefix:@"{"])
    {
      NSUInteger endPos = 0;
      return [self _parseDictFromLine:trimmedLine atPos:0 endPos:&endPos];
    }

  /* Parse inline value */
  if ([trimmedLine hasPrefix:@"\""])
    {
      NSUInteger consumed = 0;
      return [self _parseStringOnLine:trimmedLine consumed:&consumed];
    }

  NSUInteger endPos = 0;
  return [self _parseValueOnLine:trimmedLine atPos:0 endPos:&endPos];
}

/*
 * Parse a single object definition:
 * object <id>
 * {
 *     key = value;
 *     ...
 * }
 */
- (BOOL)_parseObjectInto:(MGArchive *)archive
                   error:(NSError **)error
{
  NSString *line = [self _skipBlankLines];
  if (line == nil)
    return YES; /* No more objects */

  NSString *trimmed = [line stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceCharacterSet]];

  /* Check for "object <id>" */
  if (![trimmed hasPrefix:@"object "])
    return YES; /* Not an object */

  /* Parse object ID */
  NSString *idStr = [trimmed substringFromIndex:7];
  int32_t objectId = (int32_t)[idStr intValue];

  [self _advanceLine];

  /* Expect opening brace */
  line = [self _skipBlankLines];
  if (line == nil)
    return [self _error:error
                message:@"Unexpected end of file for object %d", objectId];

  trimmed = [line stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceCharacterSet]];
  if (![trimmed isEqualToString:@"{"])
    return [self _error:error
                message:@"Expected '{' for object %d, got '%@'",
                       objectId, trimmed];

  [self _advanceLine];

  /* Create archive object */
  MGArchiveObject *obj = [[MGArchiveObject alloc] init];
  obj.objectId = objectId;
  obj.encodedValues = [NSMutableArray array];
  obj.namedProperties = [NSMutableDictionary dictionary];

  /* Parse property lines until closing brace */
  while ((line = [self _currentLine]) != nil)
    {
      trimmed = [line stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];

      if ([trimmed isEqualToString:@"}"])
        {
          [self _advanceLine];
          [archive.objects addObject:obj];
          RELEASE(obj);
          return YES;
        }

      if ([trimmed length] == 0)
        {
          [self _advanceLine];
          continue;
        }

      /* Check for values section (if no named properties) */
      if ([trimmed isEqualToString:@"values ="])
        {
          [self _advanceLine];
          /* Parse the value on next line(s) */
          NSString *valLine = [self _skipBlankLines];
          if (valLine != nil)
            {
              id val = [self _parsePropertyValueFromLine:
                [valLine stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceCharacterSet]]];
              if (val != nil)
                {
                  /* Store unnamed values as sequential keys */
                  [obj.namedProperties setObject:val
                                          forKey:@"_values"];
                }
            }
          continue;
        }

      /* Parse key = value; */
      NSScanner *scanner = [NSScanner scannerWithString:trimmed];
      NSString *key = nil;
      [scanner scanUpToString:@"=" intoString:&key];
      if (key == nil)
        {
          /* Might be a continuation line */
          [self _advanceLine];
          continue;
        }

      key = [key stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];

      [scanner scanString:@"=" intoString:NULL];

      /* Handle "class = <ClassName>;" specially */
      if ([key isEqualToString:@"class"])
        {
          NSString *classStr = nil;
          [scanner scanUpToString:@";" intoString:&classStr];
          if (classStr != nil)
            {
              obj.className = [classStr stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            }
          [self _advanceLine];
          continue;
        }

      /* Find the rest of the value (after '=') */
      NSUInteger eqPos = [trimmed rangeOfString:@"="].location;
      if (eqPos == NSNotFound)
        {
          [self _advanceLine];
          continue;
        }

      NSString *valuePart = [trimmed substringFromIndex:eqPos + 1];
      valuePart = [valuePart stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];

      BOOL isMultiline = NO;
      id val = nil;

      if ([valuePart hasPrefix:@"<data>"])
        {
          /* Data block: valuePart has the opening tag.
           * _parseDataBlockFromString advances past the entire block. */
          val = [self _parseDataBlockFromString:valuePart];
          isMultiline = YES;
        }
      else if ([valuePart hasPrefix:@"["]
          || [valuePart hasPrefix:@"{"])
        {
          /* Multi-line construct starts on this line */
          val = [self _parsePropertyValueFromLine:valuePart];
          isMultiline = YES;
        }
      else
        {
          /* Remove trailing semicolon */
          if ([valuePart hasSuffix:@";"])
            valuePart = [valuePart substringToIndex:[valuePart length] - 1];

          /* Simple inline value */
          NSUInteger valEnd = 0;
          val = [self _parseValueOnLine:valuePart atPos:0 endPos:&valEnd];
        }

      if (val != nil)
        {
          [obj.namedProperties setObject:val forKey:key];
        }

      /* Only advance if the value parser didn't already advance past the block */
      if (!isMultiline)
        [self _advanceLine];
    }

  RELEASE(obj);
  return [self _error:error
              message:@"Unterminated object definition for object %d",
                     objectId];
}

/* ============================================================
 *  Main parsing entry point
 * ============================================================ */

- (MGArchive *)_parseText:(NSString *)text
                    error:(NSError **)error
{
  /* Split into lines */
  _lines = [text componentsSeparatedByString:@"\n"];
  _idx = 0;
  _lineno = 1;

  MGArchive *archive = [[MGArchive alloc] init];
  archive.objects = [NSMutableArray array];
  archive.classDefs = [NSMutableArray array];
  archive.selectorValues = [NSMutableArray array];
  archive.cstringValues = [NSMutableArray array];
  archive.ptrValues = [NSMutableArray array];

  /* Parse header */
  NSString *line = [self _skipBlankLines];
  if (line == nil)
    {
      RELEASE(archive);
      return nil;
    }

  NSString *trimmed = [line stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceCharacterSet]];
  if (![trimmed hasPrefix:@"gorm-text"])
    {
      if (error)
        {
          *error = [NSError errorWithDomain:@"MGTextReaderErrorDomain"
                                       code:1
                                   userInfo:@{NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                       @"Not a gorm-text file (line %lu)",
                                       (unsigned long)_lineno]}];
        }
      RELEASE(archive);
      return nil;
    }

  [self _advanceLine];

  /* Parse metadata (optional) */
  if (![self _parseMetadataInto:archive error:error])
    {
      RELEASE(archive);
      return nil;
    }

  /* Parse objects */
  while (YES)
    {
      NSUInteger savedIdx = _idx;
      if (![self _parseObjectInto:archive error:error])
        {
          if (_idx == savedIdx && [self _currentLine] == nil)
            break;
          RELEASE(archive);
          return nil;
        }
      if (_idx >= [_lines count])
        break;
    }

  /* Set counts */
  archive.objectCount = (unsigned)[archive.objects count];

  return AUTORELEASE(archive);
}

/* ============================================================
 *  Public API
 * ============================================================ */

+ (MGArchive *)archiveFromText:(NSString *)text error:(NSError **)error
{
  MGTextReader *reader = [[self alloc] init];
  MGArchive *archive = [reader _parseText:text error:error];
  RELEASE(reader);
  return archive;
}

+ (MGArchive *)archiveFromPath:(NSString *)path error:(NSError **)error
{
  NSString *text = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:error];
  if (text == nil)
    return nil;

  return [self archiveFromText:text error:error];
}

@end
