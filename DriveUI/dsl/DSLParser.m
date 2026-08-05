/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * AST + parser for the GNUstep UI Automation DSL (see DSL.h / Executor.md).
 *
 * The parser consumes the lexer token stream one line (command) at a time and
 * emits DSLCommand nodes.  It owns the included-file handling and the
 * `set VAR=...` variable declarations, which live in DSLProgram.
 */

#import "DSL.h"

@implementation DSLCommand
- (id)initWithType:(DSLCommandType)t line:(NSUInteger)line col:(NSUInteger)col
{
  if ((self = [super init]))
    {
      type_ = t;
      role_ = DDSRoleAny;
      assertKind_ = DDSAssertExists;
      string_ = nil;
      string2_ = nil;
      words_ = [[NSMutableArray alloc] init];
      line_ = line;
      col_ = col;
    }
  return self;
}
- (void)dealloc
{
  [string_ release];
  [string2_ release];
  [words_ release];
  [super dealloc];
}
- (DSLCommandType)type { return type_; }
- (void)setType:(DSLCommandType)t { type_ = t; }
- (DSLRole)role { return role_; }
- (void)setRole:(DSLRole)r { role_ = r; }
- (DSLAssertKind)assertKind { return assertKind_; }
- (void)setAssertKind:(DSLAssertKind)k { assertKind_ = k; }
- (NSString *)string { return string_; }
- (void)setString:(NSString *)s { [s retain]; [string_ release]; string_ = s; }
- (NSString *)string2 { return string2_; }
- (void)setString2:(NSString *)s { [s retain]; [string2_ release]; string2_ = s; }
- (NSMutableArray *)words { return words_; }
- (NSUInteger)line { return line_; }
- (void)setLine:(NSUInteger)l { line_ = l; }
- (NSUInteger)col { return col_; }
- (void)setCol:(NSUInteger)c { col_ = c; }
@end

@implementation DSLProgram
- (id)init
{
  if ((self = [super init]))
    {
      commands_ = [[NSMutableArray alloc] init];
      variables_ = [[NSMutableDictionary alloc] init];
      currentDef_ = nil;
    }
  return self;
}
- (void)dealloc
{
  [commands_ release];
  [variables_ release];
  [currentDef_ release];
  [super dealloc];
}
- (NSMutableArray *)commands { return commands_; }
- (NSMutableDictionary *)variables { return variables_; }
- (NSString *)currentDef { return currentDef_; }
- (void)setCurrentDef:(NSString *)d { [d retain]; [currentDef_ release]; currentDef_ = d; }
@end

/* Maps a DSL object-type keyword to a DSLRole. */
DSLRole DSLRoleFromName(NSString *name)
{
  static NSDictionary *map = nil;
  if (!map)
    map = [[NSDictionary alloc] initWithObjectsAndKeys:
      @(DDSRoleApplication), @"application",
      @(DDSRoleWindow), @"window",
      @(DDSRoleDialog), @"dialog",
      @(DDSRoleSheet), @"sheet",
      @(DDSRoleButton), @"button",
      @(DDSRoleMenu), @"menu",
      @(DDSRoleMenuItem), @"menuitem",
      @(DDSRoleTextField), @"textfield",
      @(DDSRoleTextArea), @"textarea",
      @(DDSRoleCheckbox), @"checkbox",
      @(DDSRoleRadio), @"radio",
      @(DDSRolePopup), @"popup",
      @(DDSRoleComboBox), @"combobox",
      @(DDSRoleTable), @"table",
      @(DDSRoleRow), @"row",
      @(DDSRoleColumn), @"column",
      @(DDSRoleList), @"list",
      @(DDSRoleImage), @"image",
      @(DDSRoleToolbar), @"toolbar",
      @(DDSRoleTab), @"tab",
      @(DDSRoleTabItem), @"tabitem",
      @(DDSRoleSlider), @"slider",
      @(DDSRoleProgress), @"progress",
      @(DDSRoleLabel), @"label",
      nil];
  NSNumber *n = [map objectForKey: [name lowercaseString]];
  return n ? (DSLRole)[n intValue] : DDSRoleAny;
}

/* Maps a role to the ObjC class substring used to filter drive_ui snapshots.
 * Snapshots carry the real ObjC class name in field 2, so we match a prefix. */
NSString *DSLRoleClassName(DSLRole role)
{
  switch (role)
    {
      case DDSRoleWindow:  case DDSRoleDialog:  case DDSRoleSheet:
        return @"NSWindow";
      case DDSRoleButton:                       return @"NSButton";
      case DDSRoleMenu:                         return @"NSMenu";
      case DDSRoleMenuItem:                     return @"NSMenuItem";
      case DDSRoleTextField:                    return @"NSTextField";
      case DDSRoleTextArea:                     return @"NSTextView";
      case DDSRoleCheckbox:                     return @"NSButton";
      case DDSRoleRadio:                        return @"NSButton";
      case DDSRolePopup:                        return @"NSPopUpButton";
      case DDSRoleComboBox:                     return @"NSComboBox";
      case DDSRoleTable:                        return @"NSTableView";
      case DDSRoleRow:                          return @"NSTableViewRow"; /* approximate */
      case DDSRoleColumn:                       return @"NSTableColumn";
      case DDSRoleList:                         return @"NSTableView";
      case DDSRoleImage:                        return @"NSImageView";
      case DDSRoleToolbar:                      return @"NSToolbar";
      case DDSRoleTab:        case DDSRoleTabItem:  return @"NSTabView";
      case DDSRoleSlider:                       return @"NSSlider";
      case DDSRoleProgress:                     return @"NSProgressIndicator";
      case DDSRoleLabel:                        return @"NSTextField";
      default:                                  return nil;
    }
}

@implementation DSLParser

- (DSLProgram *)parseFile:(NSString *)path error:(NSString **)err
{
  NSString *text = [NSString stringWithContentsOfFile: path
    encoding: NSUTF8StringEncoding error: nil];
  if (!text)
    {
      text = [NSString stringWithContentsOfFile: path
        encoding: NSISOLatin1StringEncoding error: nil];
    }
  if (!text)
    {
      if (err) *err = [NSString stringWithFormat: @"cannot read script file %@", path];
      return nil;
    }
  DSLProgram *prog = [[[DSLProgram alloc] init] autorelease];
  if (![self parseString: text sourceName: path program: prog error: err])
    return nil;
  return prog;
}

- (DSLProgram *)parseString:(NSString *)text sourceName:(NSString *)name
                     program:(DSLProgram *)prog error:(NSString **)err
{
  NSArray *lines = [text componentsSeparatedByString: @"\n"];
  NSUInteger lineNo = 0;
  for (NSString *rawLine in lines)
    {
      lineNo++;
      NSString *line = rawLine;
      NSRange hash = [line rangeOfString: @"#"];
      if (hash.location != NSNotFound)
        line = [line substringToIndex: hash.location];
      line = [line stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
      if ([line length] == 0) continue;

      if ([line hasPrefix: @"include "])
        {
          NSString *incPath = [line substringFromIndex: [@"include " length]];
          incPath = [incPath stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
          if ([incPath hasPrefix: @"\""] && [incPath hasSuffix: @"\""]
              && [incPath length] >= 2)
            incPath = [incPath substringWithRange: NSMakeRange(1, [incPath length] - 2)];
          NSString *dir = [name stringByDeletingLastPathComponent];
          NSString *full = [dir stringByAppendingPathComponent: incPath];
          NSString *incText = [NSString stringWithContentsOfFile: full
            encoding: NSUTF8StringEncoding error: nil];
          if (!incText)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: cannot include %@",
                name, (unsigned long)lineNo, incPath];
              return nil;
            }
          if (![self parseString: incText sourceName: full program: prog error: err])
            return nil;
          continue;
        }

      if ([line hasPrefix: @"set "])
        {
          /* set VAR="value" - a variable declaration. */
          NSString *rest = [line substringFromIndex: [@"set " length]];
          NSRange eq = [rest rangeOfString: @"="];
          if (eq.location == NSNotFound || eq.location == 0)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: malformed set (need VAR=\"value\")",
                name, (unsigned long)lineNo];
              return nil;
            }
          NSString *var = [[rest substringToIndex: eq.location]
            stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
          NSString *val = [[rest substringFromIndex: eq.location + 1]
            stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
          if ([val hasPrefix: @"\""] && [val hasSuffix: @"\""] && [val length] >= 2)
            val = [val substringWithRange: NSMakeRange(1, [val length] - 2)];
          val = [val stringByReplacingOccurrencesOfString: @"\\\"" withString: @"\""];
          val = [val stringByReplacingOccurrencesOfString: @"\\\\" withString: @"\\"];
          [[prog variables] setObject: val forKey: var];
          continue;
        }

      /* Expand ${VAR} references before tokenising so quoted strings that
       * contain variables are handled uniformly. */
      for (NSString *key in [[prog variables] allKeys])
        {
          NSString *placeholder = [NSString stringWithFormat: @"${%@}", key];
          line = [line stringByReplacingOccurrencesOfString: placeholder
            withString: [[prog variables] objectForKey: key]];
        }

      /* Regular command line: split into words and quoted strings, honouring
       * embedded spaces inside quotes (e.g. type "to the moon"). */
      NSScanner *scanner = [NSScanner scannerWithString: line];
      NSMutableArray *words = [NSMutableArray array];
      NSString *str1 = nil;
      [scanner setCharactersToBeSkipped: [NSCharacterSet whitespaceCharacterSet]];
      while ([scanner isAtEnd] == NO)
        {
          NSString *tok = nil;
          if ([scanner scanString: @"\"" intoString: NULL])
            {
              NSMutableString *acc = [NSMutableString string];
              NSString *piece = nil;
              while ([scanner scanUpToString: @"\"" intoString: &piece])
                [acc appendString: piece];
              if ([scanner isAtEnd])  /* unterminated quote */
                {
                  if (err) *err = [NSString stringWithFormat: @"%@:%lu: unterminated string",
                    name, (unsigned long)lineNo];
                  return nil;
                }
              [scanner scanString: @"\"" intoString: NULL];  /* consume closing quote */
              /* handle struggled escapes */
              NSString *s = [[[acc copy] autorelease]
                stringByReplacingOccurrencesOfString: @"\\\"" withString: @"\""];
              s = [s stringByReplacingOccurrencesOfString: @"\\\\" withString: @"\\"];
              if (!str1) str1 = s;
            }
          else if ([scanner scanUpToString: @"\"" intoString: &tok])
            {
              /* tok may contain a trailing quote that begins a quoted string;
               * trim any (no inner spaces expected in unquoted tokens). */
              tok = [tok stringByReplacingOccurrencesOfString: @"\"" withString: @""];
              NSArray *sub = [tok componentsSeparatedByCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
              [words addObjectsFromArray: sub];
            }
        }
      [words removeObject: @""];

      NSString *kw = [words count] > 0 ? [[words objectAtIndex: 0] lowercaseString] : nil;
      if (kw == nil)
        {
          if (err) *err = [NSString stringWithFormat: @"%@:%lu: empty command",
            name, (unsigned long)lineNo];
          return nil;
        }
      [words removeObjectAtIndex: 0];

      DSLCommand *cmd = nil;
      if ([kw isEqualToString: @"activate"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdActivate
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"focus"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdFocusWindow
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"select"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdSelectMenu
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"click"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdClick
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? DSLRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0) [words removeObjectAtIndex: 0];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"doubleclick"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdDoubleClick
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? DSLRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0) [words removeObjectAtIndex: 0];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"rightclick"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdRightClick
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? DSLRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0) [words removeObjectAtIndex: 0];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"type"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdType
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"clear"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdClear
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? DSLRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0) [words removeObjectAtIndex: 0];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"press"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdPress
            line: lineNo col: 1] autorelease];
          cmd.string = ([words count] > 0) ? [words objectAtIndex: 0] : str1;
        }
      else if ([kw isEqualToString: @"wait"])
        {
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"until"])
            {
              cmd = [[[DSLCommand alloc] initWithType: DDSCmdWaitUntil
                line: lineNo col: 1] autorelease];
              [words removeObjectAtIndex: 0];
              if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"not"])
                {
                  cmd.assertKind = DDSAssertNotExists;
                  [words removeObjectAtIndex: 0];
                }
              if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"exists"])
                [words removeObjectAtIndex: 0];
              cmd.role = ([words count] > 0) ? DSLRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
              if ([words count] > 0) [words removeObjectAtIndex: 0];
              cmd.string = str1;
              /* optional trailing timeout 30s / 100ms */
              if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"timeout"])
                {
                  if ([words count] > 1)
                    [cmd.words addObject: [words objectAtIndex: 1]];
                }
            }
          else
            {
              cmd = [[[DSLCommand alloc] initWithType: DDSCmdWait
                line: lineNo col: 1] autorelease];
              cmd.string = ([words count] > 0) ? [words objectAtIndex: 0] : nil;
            }
        }
      else if ([kw isEqualToString: @"assert"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdAssert
            line: lineNo col: 1] autorelease];
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"not"])
            {
              cmd.assertKind = DDSAssertNotExists;
              [words removeObjectAtIndex: 0];
            }
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"exists"])
            [words removeObjectAtIndex: 0];
          /* assert text contains "..." */
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"text"])
            {
              [words removeObjectAtIndex: 0];
              if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"contains"])
                {
                  cmd.assertKind = DDSAssertContains;
                  [words removeObjectAtIndex: 0];
                  cmd.string = str1;
                }
            }
          else
            {
              cmd.role = ([words count] > 0) ? DSLRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
              if ([words count] > 0) [words removeObjectAtIndex: 0];
              cmd.string = str1;
              if ([words count] > 0)
                {
                  NSString *prop = [[words objectAtIndex: 0] lowercaseString];
                  if ([prop isEqualToString: @"enabled"]) cmd.assertKind = DDSAssertEnabled;
                  else if ([prop isEqualToString: @"checked"]) cmd.assertKind = DDSAssertChecked;
                }
            }
        }
      else if ([kw isEqualToString: @"capture"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdCapture
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"log"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdLog
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"on_error"])
        {
          cmd = [[[DSLCommand alloc] initWithType: DDSCmdOptions
            line: lineNo col: 1] autorelease];
          [cmd.words addObjectsFromArray: words];
        }
      else
        {
          if (err) *err = [NSString stringWithFormat: @"%@:%lu: unknown command '%@'",
            name, (unsigned long)lineNo, kw];
          return nil;
        }

      [[prog commands] addObject: cmd];
    }
  return prog;
}

@end