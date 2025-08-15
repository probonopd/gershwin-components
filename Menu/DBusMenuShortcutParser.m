#import "DBusMenuShortcutParser.h"

@implementation DBusMenuShortcutParser

+ (NSString *)parseShortcutArray:(NSArray *)shortcutArray
{
    // Convert DBus shortcut array to string format
    // DBus shortcuts are typically nested arrays like ((Control, t)) or ((Control, Shift, x))
    if (![shortcutArray isKindOfClass:[NSArray class]] || [shortcutArray count] == 0) {
        NSLog(@"DBusMenuShortcutParser: Invalid shortcut array - not array or empty");
        return nil;
    }
    
    NSLog(@"DBusMenuShortcutParser: Parsing shortcut array: %@", shortcutArray);
    
    // The shortcut array might be nested - check if first element is an array
    NSArray *actualShortcut = shortcutArray;
    if ([shortcutArray count] > 0 && [[shortcutArray objectAtIndex:0] isKindOfClass:[NSArray class]]) {
        // Take the first nested array - this is the actual shortcut
        actualShortcut = [shortcutArray objectAtIndex:0];
        NSLog(@"DBusMenuShortcutParser: Found nested shortcut array: %@", actualShortcut);
    }
    
    NSMutableArray *components = [NSMutableArray array];
    NSString *key = nil;
    
    for (id item in actualShortcut) {
        if ([item isKindOfClass:[NSString class]]) {
            NSString *component = (NSString *)item;
            NSLog(@"DBusMenuShortcutParser: Processing shortcut component: '%@'", component);
            
            // Check if it's a modifier - map modifiers
            if ([component isEqualToString:@"Control_L"] || [component isEqualToString:@"Control_R"] || 
                [component isEqualToString:@"Control"] || [component isEqualToString:@"ctrl"]) {
                [components addObject:@"ctrl"]; // Control key
                NSLog(@"DBusMenuShortcutParser: Added Control modifier");
            } else if ([component isEqualToString:@"Shift_L"] || [component isEqualToString:@"Shift_R"] || 
                       [component isEqualToString:@"Shift"] || [component isEqualToString:@"shift"]) {
                [components addObject:@"shift"];
                NSLog(@"DBusMenuShortcutParser: Added Shift modifier");
            } else if ([component isEqualToString:@"Alt_L"] || [component isEqualToString:@"Alt_R"] || 
                       [component isEqualToString:@"Alt"] || [component isEqualToString:@"alt"]) {
                [components addObject:@"alt"];
                NSLog(@"DBusMenuShortcutParser: Added Alt modifier");
            } else if ([component isEqualToString:@"Meta_L"] || [component isEqualToString:@"Meta_R"] || 
                       [component isEqualToString:@"Super_L"] || [component isEqualToString:@"Super_R"] ||
                       [component isEqualToString:@"Meta"] || [component isEqualToString:@"Super"]) {
                [components addObject:@"cmd"]; // Command/Super key
                NSLog(@"DBusMenuShortcutParser: Added Command modifier");
            } else {
                // This should be the key
                key = [self normalizeKeyName:component];
                NSLog(@"DBusMenuShortcutParser: Found key: '%@' -> '%@'", component, key);
            }
        } else if ([item isKindOfClass:[NSNumber class]]) {
            // Handle numeric keysyms
            NSNumber *keysym = (NSNumber *)item;
            key = [self normalizeKeyName:[keysym stringValue]];
            NSLog(@"DBusMenuShortcutParser: Found numeric key: %@ -> '%@'", keysym, key);
        }
    }
    
    NSString *result = nil;
    if (key && [components count] > 0) {
        result = [NSString stringWithFormat:@"%@+%@", [components componentsJoinedByString:@"+"], key];
    } else if (key) {
        result = key;
    }
    
    NSLog(@"DBusMenuShortcutParser: Shortcut parsing result: '%@'", result);
    return result;
}

+ (NSDictionary *)parseKeyCombo:(NSString *)keyCombo
{
    if (!keyCombo || [keyCombo length] == 0) {
        return @{@"key": @"", @"modifiers": @0};
    }
    
    NSLog(@"DBusMenuShortcutParser: Parsing key combo: '%@'", keyCombo);
    
    NSArray *parts = [keyCombo componentsSeparatedByString:@"+"];
    NSUInteger modifierMask = 0;
    NSString *key = @"";
    
    for (NSString *part in parts) {
        NSString *cleanPart = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSLog(@"DBusMenuShortcutParser: Processing key combo part: '%@'", cleanPart);
        
        if ([cleanPart isEqualToString:@"cmd"] || [cleanPart isEqualToString:@"command"]) {
            modifierMask |= NSCommandKeyMask;
            NSLog(@"DBusMenuShortcutParser: Added Command modifier mask");
        } else if ([cleanPart isEqualToString:@"shift"]) {
            modifierMask |= NSShiftKeyMask;
            NSLog(@"DBusMenuShortcutParser: Added Shift modifier mask");
        } else if ([cleanPart isEqualToString:@"alt"] || [cleanPart isEqualToString:@"option"]) {
            modifierMask |= NSAlternateKeyMask;
            NSLog(@"DBusMenuShortcutParser: Added Alt modifier mask");
        } else if ([cleanPart isEqualToString:@"ctrl"] || [cleanPart isEqualToString:@"control"]) {
            modifierMask |= NSControlKeyMask;
            NSLog(@"DBusMenuShortcutParser: Added Control modifier mask");
        } else {
            // This should be the key
            key = [self normalizeKeyName:cleanPart];
            NSLog(@"DBusMenuShortcutParser: Set key equivalent: '%@' (from '%@')", key, cleanPart);
        }
    }
    
    NSLog(@"DBusMenuShortcutParser: Key combo result - key: '%@', modifiers: %lu", key, (unsigned long)modifierMask);
    return @{@"key": key, @"modifiers": @(modifierMask)};
}

+ (NSString *)normalizeKeyName:(NSString *)keyName
{
    if (!keyName || [keyName length] == 0) {
        return @"";
    }
    
    // Convert common key names to single characters for NSMenuItem
    NSString *normalized = [keyName lowercaseString];
    
    // Handle special keys
    if ([normalized isEqualToString:@"return"] || [normalized isEqualToString:@"enter"]) {
        return @"\r";
    } else if ([normalized isEqualToString:@"tab"]) {
        return @"\t";
    } else if ([normalized isEqualToString:@"space"]) {
        return @" ";
    } else if ([normalized isEqualToString:@"escape"] || [normalized isEqualToString:@"esc"]) {
        return @"\033";
    } else if ([normalized isEqualToString:@"backspace"]) {
        return @"\b";
    } else if ([normalized isEqualToString:@"delete"]) {
        return @"\177";
    } else if ([normalized hasPrefix:@"f"] && [normalized length] <= 3) {
        // Function keys - return as is for now, NSMenuItem will handle
        return normalized;
    } else if ([normalized length] == 1) {
        // Single character - use lowercase
        return normalized;
    }
    
    // For other keys, try to extract the first character
    if ([normalized length] > 1) {
        return [normalized substringToIndex:1];
    }
    
    return @"";
}

+ (NSString *)modifierMaskToString:(NSUInteger)modifierMask
{
    NSMutableArray *modifiers = [NSMutableArray array];
    
    if (modifierMask & NSCommandKeyMask) {
        [modifiers addObject:@"⌘"];
    }
    if (modifierMask & NSShiftKeyMask) {
        [modifiers addObject:@"⇧"];
    }
    if (modifierMask & NSAlternateKeyMask) {
        [modifiers addObject:@"⌥"];
    }
    if (modifierMask & NSControlKeyMask) {
        [modifiers addObject:@"⌃"];
    }
    
    return [modifiers componentsJoinedByString:@""];
}

+ (NSDictionary *)testParseKeyCombo:(NSString *)keyCombo
{
    return [self parseKeyCombo:keyCombo];
}

@end
