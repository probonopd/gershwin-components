/*
 * UIBridgeService — see UIBridgeService.h for the rationale.
 */

#import "UIBridgeService.h"
#import <string.h>

#ifdef UIBRIDGE_DEBUG
#define UBLOG(...) NSLog(__VA_ARGS__)
#else
#define UBLOG(...) do {} while (0)
#endif

@interface UIBridgeService ()
- (NSString *)_objectIDForObject:(id)obj;
- (id)_objectForID:(NSString *)objID;
- (id)_serializeObject:(id)obj detailed:(BOOL)detailed depth:(int)depth;
- (NSDictionary *)_serializeMenuWithIndexPaths:(NSMenu *)menu;
- (NSMenuItem *)_menuItemForIndexPath:(NSArray *)indexPath inMenu:(NSMenu *)menu;
- (NSMenu *)_menuSourceForWindowId:(NSNumber *)windowId;
- (void)_runOnMain:(void (^)(void))block;
@end

@implementation UIBridgeService

- (id)init
{
  if ((self = [super init]) != nil) {
    /* Forward map: strong string id -> weak object. A weak value auto-nils
       when the object is deallocated, so a stale lookup returns nil safely. */
    _idToObject = [NSMapTable strongToWeakObjectsMapTable];
    /* Reverse map (id reuse only): weak object -> strong string id. */
    _objectToID = [NSMapTable weakToStrongObjectsMapTable];
    _idCounter = 0;
  }
  return self;
}

#pragma mark - Main-thread dispatch helper

/* All protocol methods touch AppKit and the registry from here. The service is
   vended single-threaded on the main run loop, so DO requests already arrive on
   the main thread (direct call); the dispatch_sync branch only matters if a
   caller ever invokes off-main, and never deadlocks because we check first. */
- (void)_runOnMain:(void (^)(void))block
{
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_sync(dispatch_get_main_queue(), block);
  }
}

#pragma mark - id <-> object registry (replaces the pointer-cast UAF)

- (NSString *)_objectIDForObject:(id)obj
{
  if (!obj) return @"";
  @synchronized (self) {
    NSString *existing = [_objectToID objectForKey:obj];
    if (existing) return existing;
    NSString *newID = [NSString stringWithFormat:@"objc:%lu", (unsigned long)(++_idCounter)];
    [_idToObject setObject:obj forKey:newID];
    [_objectToID setObject:newID forKey:obj];
    return newID;
  }
}

- (id)_objectForID:(NSString *)objID
{
  if (!objID) return nil;
  if ([objID isEqualToString:@"NSApp"]) return NSApp;
  if (![objID hasPrefix:@"objc:"]) return nil;
  @synchronized (self) {
    /* Weak map: returns nil if the object has been deallocated. No cast, no
       resurrection of a freed pointer. */
    return [_idToObject objectForKey:objID];
  }
}

#pragma mark - UIBridgeProtocol: object tree

- (bycopy id)rootObjects
{
  __block NSDictionary *result = nil;
  [self _runOnMain:^{
    NSMutableArray *wins = [NSMutableArray array];
    for (NSWindow *w in [NSApp windows]) {
      NSMutableDictionary *d = [NSMutableDictionary dictionary];
      d[@"object_id"] = [self _objectIDForObject:w];
      d[@"class"] = NSStringFromClass([w class]);
      d[@"title"] = [w title] ?: @"";
      d[@"frame"] = NSStringFromRect([w frame]);
      d[@"windowNumber"] = @([w windowNumber]);
      d[@"hidden"] = @(![w isVisible]);
      [wins addObject:d];
    }
    result = @{ @"NSApp": [self _objectIDForObject:NSApp], @"windows": wins };
  }];
  return result ?: @{ @"NSApp": @"", @"windows": @[] };
}

- (id)_serializeObject:(id)obj detailed:(BOOL)detailed depth:(int)depth
{
  if (!obj || obj == [NSNull null] || depth < 0) return [NSNull null];
  if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) return obj;

  NSString *className = @"Unknown";
  @try { className = NSStringFromClass([obj class]); } @catch (NSException *e) { }

  NSMutableDictionary *dict = [NSMutableDictionary dictionary];
  dict[@"object_id"] = [self _objectIDForObject:obj];
  dict[@"class"] = className;

  if ([obj isKindOfClass:[NSView class]]) {
    NSView *view = (NSView *)obj;
    dict[@"frame"] = NSStringFromRect([view frame]);
    dict[@"hidden"] = @([view isHidden]);

    if ([view respondsToSelector:@selector(title)]) {
      id title = [view performSelector:@selector(title)];
      if (title && ![title isEqual:@""]) dict[@"title"] = title;
    }
    if ([view isKindOfClass:[NSTextField class]]) {
      NSTextField *tf = (NSTextField *)view;
      dict[@"stringValue"] = [tf stringValue] ?: @"";
      dict[@"string"] = [tf stringValue] ?: @"";
    }

    @try {
      if ([view window]) {
        NSRect winRect = [view convertRect:[view bounds] toView:nil];
        dict[@"window_frame"] = NSStringFromRect(winRect);
        NSRect screenRect = [[view window] convertRectToScreen:winRect];
        dict[@"screen_frame"] = NSStringFromRect(screenRect);
      }
    } @catch (NSException *e) { }

    if ([view isKindOfClass:[NSControl class]]) {
      NSControl *control = (NSControl *)view;
      dict[@"enabled"] = @([control isEnabled]);
      dict[@"tag"] = @([control tag]);
    }
    if ([view isKindOfClass:[NSButton class]]) {
      NSButton *button = (NSButton *)view;
      dict[@"keyEquivalent"] = [button keyEquivalent] ?: @"";
      dict[@"keyModifiers"] = @([button keyEquivalentModifierMask]);
    }

    if (detailed && depth > 0) {
      NSMutableArray *subviews = [NSMutableArray array];
      for (NSView *sub in [view subviews]) {
        [subviews addObject:[self _serializeObject:sub detailed:YES depth:depth - 1]];
      }
      dict[@"subviews"] = subviews;
    }
  }

  if ([obj isKindOfClass:[NSWindow class]]) {
    NSWindow *win = (NSWindow *)obj;
    dict[@"title"] = [win title] ?: @"";
    dict[@"frame"] = NSStringFromRect([win frame]);
    dict[@"hidden"] = @(![win isVisible]);
    if (detailed && depth > 0) {
      dict[@"contentView"] = [self _serializeObject:[win contentView] detailed:YES depth:depth - 1];
    }
  }

  if ([obj isKindOfClass:[NSApplication class]]) {
    NSApplication *app = (NSApplication *)obj;
    if (detailed && depth > 0) {
      NSMutableArray *wins = [NSMutableArray array];
      for (NSWindow *win in [app windows]) {
        [wins addObject:[self _serializeObject:win detailed:YES depth:depth - 1]];
      }
      dict[@"windows"] = wins;
    }
  }

  if ([obj isKindOfClass:[NSMenu class]]) {
    NSMenu *menu = (NSMenu *)obj;
    dict[@"title"] = [menu title] ?: @"";
    if (detailed && depth > 0) {
      NSMutableArray *items = [NSMutableArray array];
      for (NSMenuItem *item in [menu itemArray]) {
        [items addObject:[self _serializeObject:item detailed:YES depth:depth - 1]];
      }
      dict[@"items"] = items;
    }
  }

  if ([obj isKindOfClass:[NSMenuItem class]]) {
    NSMenuItem *item = (NSMenuItem *)obj;
    dict[@"title"] = [item title] ?: @"";
    dict[@"enabled"] = @([item isEnabled]);
    dict[@"hasSubmenu"] = @([item hasSubmenu]);
    dict[@"isSeparator"] = @([item isSeparatorItem]);
    if ([item action]) dict[@"action"] = NSStringFromSelector([item action]);
    if ([item keyEquivalent]) dict[@"keyEquivalent"] = [item keyEquivalent];
    dict[@"keyModifiers"] = @([item keyEquivalentModifierMask]);
    dict[@"tag"] = @([item tag]);
    dict[@"state"] = @([item state]);
    if ([item hasSubmenu] && detailed && depth > 0) {
      dict[@"submenu"] = [self _serializeObject:[item submenu] detailed:YES depth:depth - 1];
    }
  }

  return dict;
}

- (bycopy id)detailsForObject:(NSString *)objID
{
  __block id result = nil;
  [self _runOnMain:^{
    if (objID && [objID hasPrefix:@"menuitem:"]) {
      NSArray *parts = [objID componentsSeparatedByString:@":"];
      if ([parts count] >= 3) {
        NSNumber *windowId = @([parts[1] longLongValue]);
        NSArray *components = [parts[2] componentsSeparatedByString:@"."];
        NSMutableArray *indexPath = [NSMutableArray array];
        for (NSString *c in components) [indexPath addObject:@([c integerValue])];
        NSMenuItem *it = [self _menuItemForIndexPath:indexPath
                                              inMenu:[self _menuSourceForWindowId:windowId]];
        if (it) { result = [self _serializeObject:it detailed:YES depth:2]; return; }
      }
    }
    id obj = [self _objectForID:objID];
    result = obj ? [self _serializeObject:obj detailed:YES depth:2] : [NSNull null];
  }];
  return result ?: [NSNull null];
}

- (bycopy id)fullTreeForObject:(NSString *)objID
{
  __block id result = nil;
  [self _runOnMain:^{
    id obj = nil;
    if (!objID || [objID length] == 0 || [objID isEqualToString:@"NSApp"]) {
      obj = NSApp;
    } else {
      obj = [self _objectForID:objID];
    }
    if (obj) {
      result = [self _serializeObject:obj detailed:YES depth:15];
    } else {
      result = @{ @"menus": [self listMenus] };
    }
  }];
  return result ?: [NSNull null];
}

- (bycopy id)invokeSelector:(NSString *)selectorName onObject:(NSString *)objID withArgs:(NSArray *)args
{
  __block id result = nil;
  [self _runOnMain:^{
    if (selectorName && [selectorName isEqualToString:@"invokeMenuItemByID:"] && [args count] > 0) {
      result = [self invokeMenuItem:args[0]] ? @YES : @NO;
      return;
    }

    id obj = [self _objectForID:objID];
    if (!obj) {
      result = @{ @"error": @{ @"code": @-32000, @"message": @"Object not found" } };
      return;
    }

    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) {
      result = @{ @"error": @{ @"code": @-32601, @"message": @"Selector not found" } };
      return;
    }

    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:obj];
    [inv setSelector:sel];

    if ([args isKindOfClass:[NSArray class]]) {
      for (NSUInteger i = 0; i < [args count]; i++) {
        NSUInteger ai = i + 2;
        if (ai >= [sig numberOfArguments]) break;
        id arg = args[i];
        if (arg == [NSNull null]) arg = nil;

        /* Marshal each argument according to the method's REAL parameter type
           (decoding NSNumber -> primitive). Writing every arg as an id — as the
           original UIBridge did — shoves an object pointer into a primitive/struct
           slot (type confusion). */
        const char *t = [sig getArgumentTypeAtIndex:ai];
        while (*t && strchr("rnNoORV", *t)) t++;     /* skip type qualifiers */
        char k = *t;
        if (k == '@' || k == '#') {
          [inv setArgument:&arg atIndex:ai];
        } else if (k == 'B') {
          BOOL v = [arg boolValue]; [inv setArgument:&v atIndex:ai];
        } else if (k == 'f') {
          float v = (float)[arg doubleValue]; [inv setArgument:&v atIndex:ai];
        } else if (k == 'd') {
          double v = [arg doubleValue]; [inv setArgument:&v atIndex:ai];
        } else if (strchr("cCsSiIlLqQ", k)) {
          long long ll = [arg longLongValue];
          switch (k) {
            case 'c': { char v = (char)ll; [inv setArgument:&v atIndex:ai]; break; }
            case 'C': { unsigned char v = (unsigned char)ll; [inv setArgument:&v atIndex:ai]; break; }
            case 's': { short v = (short)ll; [inv setArgument:&v atIndex:ai]; break; }
            case 'S': { unsigned short v = (unsigned short)ll; [inv setArgument:&v atIndex:ai]; break; }
            case 'i': { int v = (int)ll; [inv setArgument:&v atIndex:ai]; break; }
            case 'I': { unsigned int v = (unsigned int)ll; [inv setArgument:&v atIndex:ai]; break; }
            case 'l': { long v = (long)ll; [inv setArgument:&v atIndex:ai]; break; }
            case 'L': { unsigned long v = (unsigned long)ll; [inv setArgument:&v atIndex:ai]; break; }
            case 'q': { long long v = ll; [inv setArgument:&v atIndex:ai]; break; }
            case 'Q': { unsigned long long v = (unsigned long long)ll; [inv setArgument:&v atIndex:ai]; break; }
          }
        } else {
          /* struct / pointer / SEL / etc. — refuse rather than corrupt the call */
          result = @{ @"error": @{ @"code": @-32602,
                      @"message": [NSString stringWithFormat:@"unsupported arg type '%s' at index %lu",
                                   t, (unsigned long)i] } };
          return;
        }
      }
    }

    @try {
      [inv invoke];
      if ([sig methodReturnLength] > 0) {
        const char *retType = [sig methodReturnType];
        if (retType[0] == '@' || retType[0] == '#') {
          id retVal = nil;
          [inv getReturnValue:&retVal];
          result = [self _serializeObject:retVal detailed:NO depth:1];
        } else {
          result = @{ @"ok": @YES };
        }
      } else {
        result = @{ @"ok": @YES };
      }
    } @catch (NSException *e) {
      result = @{ @"error": @{ @"code": @-32001, @"message": [e reason] ?: @"invocation failed" } };
    }
  }];
  return result ?: [NSNull null];
}

#pragma mark - UIBridgeProtocol: menus (theme-independent, against NSApp)

/* Resolve the NSMenu for a windowId: a real window's own menu if it has one,
   otherwise the application main menu. windowId 0/nil/NSNull => main menu. */
- (NSMenu *)_menuSourceForWindowId:(NSNumber *)windowId
{
  if (windowId && ![windowId isEqual:[NSNull null]] && [windowId integerValue] != 0) {
    for (NSWindow *w in [NSApp windows]) {
      if ([w windowNumber] == [windowId integerValue]) {
        NSMenu *m = [w menu];
        if (m) return m;
        break;
      }
    }
  }
  return [NSApp mainMenu];
}

- (NSDictionary *)_serializeMenuWithIndexPaths:(NSMenu *)menu
{
  if (menu == nil) return nil;
  NSMutableArray *items = [NSMutableArray array];
  NSArray *itemArray = [menu itemArray];
  for (NSUInteger i = 0; i < [itemArray count]; i++) {
    NSMenuItem *item = itemArray[i];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = ([item title] ?: @"");
    d[@"enabled"] = @([item isEnabled]);
    d[@"state"] = @([item state]);
    d[@"isSeparator"] = @([item isSeparatorItem]);
    d[@"indexPath"] = @[@(i)];
    if ([item hasSubmenu]) d[@"submenu"] = [self _serializeMenuWithIndexPaths:[item submenu]];
    [items addObject:d];
  }
  return @{ @"title": ([menu title] ?: @""), @"items": items };
}

- (NSMenuItem *)_menuItemForIndexPath:(NSArray *)indexPath inMenu:(NSMenu *)menu
{
  if (menu == nil || [indexPath count] == 0) return nil;
  NSMenu *currentMenu = menu;
  NSMenuItem *currentItem = nil;
  for (NSUInteger i = 0; i < [indexPath count]; i++) {
    NSInteger index = [[indexPath objectAtIndex:i] integerValue];
    if (index < 0 || index >= [currentMenu numberOfItems]) return nil;
    currentItem = [currentMenu itemAtIndex:index];
    if (i < [indexPath count] - 1) {
      if (![currentItem hasSubmenu]) return nil;
      currentMenu = [currentItem submenu];
    }
  }
  return currentItem;
}

- (bycopy NSArray *)listMenus
{
  __block NSMutableArray *result = nil;
  [self _runOnMain:^{
    result = [NSMutableArray array];

    NSWindow *keyWindow = [NSApp keyWindow];
    if (!keyWindow && [[NSApp windows] count] > 0) keyWindow = [[NSApp windows] objectAtIndex:0];
    if (keyWindow && [keyWindow menu]) {
      [result addObject:@{ @"windowId": @([keyWindow windowNumber]),
                           @"menu": [self _serializeMenuWithIndexPaths:[keyWindow menu]] }];
    }

    NSMenu *appMainMenu = [NSApp mainMenu];
    if (appMainMenu) {
      [result addObject:@{ @"windowId": [NSNull null],
                           @"menu": [self _serializeMenuWithIndexPaths:appMainMenu] }];
    }
  }];
  return result ?: [NSArray array];
}

- (BOOL)invokeMenuItem:(NSString *)objID
{
  if (!objID || ![objID hasPrefix:@"menuitem:"]) return NO;
  NSArray *parts = [objID componentsSeparatedByString:@":"];
  if ([parts count] < 3) return NO;
  NSNumber *windowId = @([parts[1] longLongValue]);
  NSMutableArray *indexPath = [NSMutableArray array];
  for (NSString *c in [parts[2] componentsSeparatedByString:@"."]) [indexPath addObject:@([c integerValue])];

  __block BOOL handled = NO;
  [self _runOnMain:^{
    @try {
      NSMenuItem *it = [self _menuItemForIndexPath:indexPath
                                            inMenu:[self _menuSourceForWindowId:windowId]];
      if (it) {
        NSMenu *owner = [it menu];
        /* performActionForItemAtIndex: routes through target/action and the
           responder chain — no theme involvement. */
        [owner performActionForItemAtIndex:[owner indexOfItem:it]];
        handled = YES;
      }
    } @catch (NSException *e) {
      UBLOG(@"UIBridge: invokeMenuItem %@ threw: %@", objID, e);
      handled = NO;
    }
  }];
  return handled;
}

#pragma mark - JSON variants

static NSString *UBJSON(id obj)
{
  NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"null";
}

- (bycopy NSString *)rootObjectsJSON { return UBJSON([self rootObjects]); }
- (bycopy NSString *)detailsForObjectJSON:(NSString *)objID { return UBJSON([self detailsForObject:objID]); }
- (bycopy NSString *)fullTreeForObjectJSON:(NSString *)objID { return UBJSON([self fullTreeForObject:objID]); }
- (bycopy NSString *)invokeSelectorJSON:(NSString *)selectorName onObject:(NSString *)objID withArgs:(NSArray *)args
{
  return UBJSON([self invokeSelector:selectorName onObject:objID withArgs:args]);
}
- (bycopy NSString *)listMenusJSON { return UBJSON([self listMenus]); }

@end
