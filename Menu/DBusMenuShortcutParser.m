/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "DBusMenuShortcutParser.h"
#import <X11/Xlib.h>
#import <X11/keysym.h>

/* Keysym ranges used to classify numeric shortcut values sent by
 * GTK / Canonical AppMenu clients.  GDK key values (which are what
 * most toolkits send over D-Bus) are nearly identical to the
 * corresponding X11 keysyms in the ASCII / Latin-1 range. */
#define XK_MODIFIER_MIN   0xFFE0u
#define XK_MODIFIER_MAX   0xFFFFu

/* Mapping table: X11 keysym → canonical modifier name.  Entries are
 * grouped by modifier so we can binary-search or simply linear-scan;
 * the table is small so a linear scan is fine. */
typedef struct {
    unsigned int  keysym;
    const char   *modName;   /* e.g. "ctrl", "shift", "alt", "cmd" */
} KeysymModEntry;

static KeysymModEntry const modifier_map[] = {
    /* Control */
    { XK_Control_L,    "ctrl" },
    { XK_Control_R,    "ctrl" },
    /* Shift */
    { XK_Shift_L,      "shift" },
    { XK_Shift_R,      "shift" },
    /* Alt */
    { XK_Alt_L,        "alt" },
    { XK_Alt_R,        "alt" },
    { XK_Meta_L,       "alt" },
    { XK_Meta_R,       "alt" },
    /* Super / Command */
    { XK_Super_L,      "cmd" },
    { XK_Super_R,      "cmd" },
    { XK_Hyper_L,      "cmd" },
    { XK_Hyper_R,      "cmd" },
};

#define NUM_MODIFIER_MAP (sizeof(modifier_map) / sizeof(modifier_map[0]))


@implementation DBusMenuShortcutParser

+ (NSString *)parseShortcutArray:(NSArray *)shortcutArray
{
    // Convert DBus shortcut array to string format
    // DBus shortcuts are typically nested arrays like ((Control, t)) or ((Control, Shift, x))
    if (![shortcutArray isKindOfClass:[NSArray class]] || [shortcutArray count] == 0) {
        NSDebugLog(@"DBusMenuShortcutParser: Invalid shortcut array - not array or empty");
        return nil;
    }
    
    NSDebugLog(@"DBusMenuShortcutParser: Parsing shortcut array: %@", shortcutArray);
    
    // The shortcut array might be nested - check if first element is an array
    NSArray *actualShortcut = shortcutArray;
    if ([shortcutArray count] > 0 && [[shortcutArray objectAtIndex:0] isKindOfClass:[NSArray class]]) {
        // Take the first nested array - this is the actual shortcut
        actualShortcut = [shortcutArray objectAtIndex:0];
        NSDebugLog(@"DBusMenuShortcutParser: Found nested shortcut array: %@", actualShortcut);
    }
    
    NSMutableArray *components = [NSMutableArray array];
    NSString *key = nil;
    
    for (id item in actualShortcut) {
        if ([item isKindOfClass:[NSString class]]) {
            NSString *component = (NSString *)item;
            NSDebugLog(@"DBusMenuShortcutParser: Processing shortcut component: '%@'", component);
            
            // Check if it's a modifier - map modifiers (case-insensitive)
            NSString *lowerComponent = [component lowercaseString];
            if ([lowerComponent isEqualToString:@"control_l"] || [lowerComponent isEqualToString:@"control_r"] || 
                [lowerComponent isEqualToString:@"control"] || [lowerComponent isEqualToString:@"ctrl"]) {
                [components addObject:@"ctrl"]; // Control key
                NSDebugLog(@"DBusMenuShortcutParser: Added Control modifier");
            } else if ([lowerComponent isEqualToString:@"shift_l"] || [lowerComponent isEqualToString:@"shift_r"] || 
                       [lowerComponent isEqualToString:@"shift"]) {
                [components addObject:@"shift"];
                NSDebugLog(@"DBusMenuShortcutParser: Added Shift modifier");
            } else if ([lowerComponent isEqualToString:@"alt_l"] || [lowerComponent isEqualToString:@"alt_r"] || 
                       [lowerComponent isEqualToString:@"alt"]) {
                [components addObject:@"alt"];
                NSDebugLog(@"DBusMenuShortcutParser: Added Alt modifier");
            } else if ([lowerComponent isEqualToString:@"meta_l"] || [lowerComponent isEqualToString:@"meta_r"] || 
                       [lowerComponent isEqualToString:@"super_l"] || [lowerComponent isEqualToString:@"super_r"] ||
                       [lowerComponent isEqualToString:@"hyper_l"] || [lowerComponent isEqualToString:@"hyper_r"] ||
                       [lowerComponent isEqualToString:@"meta"] || [lowerComponent isEqualToString:@"super"] ||
                       [lowerComponent isEqualToString:@"hyper"] || [lowerComponent isEqualToString:@"cmd"] ||
                       [lowerComponent isEqualToString:@"command"]) {
                [components addObject:@"cmd"]; // Command/Super key
                NSDebugLog(@"DBusMenuShortcutParser: Added Command modifier");
            } else {
                // This should be the key
                key = [self normalizeKeyName:component];
                NSDebugLog(@"DBusMenuShortcutParser: Found key: '%@' -> '%@'", component, key);
            }
        } else if ([item isKindOfClass:[NSNumber class]]) {
            // Handle numeric keysyms (common in GTK/Chrome apps)
            unsigned int keysymVal = [item unsignedIntValue];
            NSDebugLog(@"DBusMenuShortcutParser: Processing numeric shortcut component: %u", keysymVal);
            
            // 1. Check if it's a modifier keysym (XF86/GDK range)
            BOOL foundModifier = NO;
            for (NSUInteger i = 0; i < NUM_MODIFIER_MAP; i++) {
                if (modifier_map[i].keysym == keysymVal) {
                    NSString *modName = [NSString stringWithUTF8String:modifier_map[i].modName];
                    [components addObject:modName];
                    NSDebugLog(@"DBusMenuShortcutParser: Numeric value %u matched modifier '%@'", 
                          keysymVal, modName);
                    foundModifier = YES;
                    break;
                }
            }
            if (foundModifier) continue;
            
            // 2. Check for printable ASCII / Latin-1 range (0x20-0xFF)
            if (keysymVal >= 0x20 && keysymVal <= 0xFF) {
                // Use the Unicode/ASCII character directly.
                // Note: X11 keysyms in this range equal the corresponding
                // ASCII / Latin-1 codepoint for most practical purposes.
                unichar c = (unichar)(keysymVal & 0x7F);
                if (c >= 0x20 && c <= 0x7E) {
                    key = [NSString stringWithCharacters:&c length:1];
                    NSDebugLog(@"DBusMenuShortcutParser: Numeric value %u -> ASCII '%@'", keysymVal, key);
                    continue;
                }
            }
            
            // 3. Try X11 Keysym-to-string conversion
            char *ksName = XKeysymToString((KeySym)keysymVal);
            if (ksName) {
                NSString *ksStr = [NSString stringWithUTF8String:ksName];
                NSDebugLog(@"DBusMenuShortcutParser: Numeric value %u -> keysym name '%@'", keysymVal, ksStr);
                
                // Check keysym name for modifiers (case-insensitive)
                NSString *lowerKs = [ksStr lowercaseString];
                if ([lowerKs hasSuffix:@"_l"] || [lowerKs hasSuffix:@"_r"]) {
                    // Could be a left/right variant of a modifier
                    NSString *base = [lowerKs substringToIndex:[lowerKs length] - 2];
                    if ([base isEqualToString:@"control"] || [base isEqualToString:@"ctrl"]) {
                        [components addObject:@"ctrl"];
                        continue;
                    } else if ([base isEqualToString:@"shift"]) {
                        [components addObject:@"shift"];
                        continue;
                    } else if ([base isEqualToString:@"alt"]) {
                        [components addObject:@"alt"];
                        continue;
                    } else if ([base isEqualToString:@"meta"] || [base isEqualToString:@"super"] || 
                               [base isEqualToString:@"hyper"] || [base isEqualToString:@"cmd"]) {
                        [components addObject:@"cmd"];
                        continue;
                    }
                }
                
                // Use the keysym name as the key
                key = [self normalizeKeyName:ksStr];
                continue;
            }
            
            // 4. Last resort: try to extract a reasonable key from the numeric value
            NSDebugLog(@"DBusMenuShortcutParser: Unknown keysym %u, using string value", keysymVal);
            key = [self normalizeKeyName:[item stringValue]];
        }
    }
    
    NSString *result = nil;
    if (key && [components count] > 0) {
        result = [NSString stringWithFormat:@"%@+%@", [components componentsJoinedByString:@"+"], key];
    } else if (key) {
        result = key;
    }
    
    NSDebugLog(@"DBusMenuShortcutParser: Shortcut parsing result: '%@'", result);
    return result;
}

+ (NSDictionary *)parseKeyCombo:(NSString *)keyCombo
{
    if (!keyCombo || [keyCombo length] == 0) {
        return @{@"key": @"", @"modifiers": @0};
    }
    
    NSDebugLog(@"DBusMenuShortcutParser: Parsing key combo: '%@'", keyCombo);
    
    NSUInteger modifierMask = 0;
    NSString *key = @"";
    NSString *work = keyCombo;
    
    // Detect GTK angle-bracket accelerator format: <Control>t, <Primary><Shift>n, <Alt>F4 etc.
    // These use angle brackets around modifiers and no '+' separator.
    if ([work containsString:@"<"] && [work containsString:@">"] && ![work containsString:@"+"]) {
        NSDebugLog(@"DBusMenuShortcutParser: Detected GTK angle-bracket accelerator format");
        
        // Extract modifiers by finding <...> patterns
        while ([work containsString:@"<"] && [work containsString:@">"]) {
            NSRange openRange = [work rangeOfString:@"<"];
            NSRange closeRange = [work rangeOfString:@">"];
            if (openRange.location != NSNotFound && closeRange.location != NSNotFound &&
                closeRange.location > openRange.location) {
                NSRange modRange = NSMakeRange(openRange.location + 1, 
                                               closeRange.location - openRange.location - 1);
                NSString *modName = [work substringWithRange:modRange];
                NSString *lowerMod = [modName lowercaseString];
                
                if ([lowerMod isEqualToString:@"control"] || [lowerMod isEqualToString:@"primary"] ||
                    [lowerMod isEqualToString:@"ctrl"]) {
                    modifierMask |= NSControlKeyMask;
                } else if ([lowerMod isEqualToString:@"shift"]) {
                    modifierMask |= NSShiftKeyMask;
                } else if ([lowerMod isEqualToString:@"alt"]) {
                    modifierMask |= NSAlternateKeyMask;
                } else if ([lowerMod isEqualToString:@"meta"] || [lowerMod isEqualToString:@"super"] ||
                           [lowerMod isEqualToString:@"hyper"] || [lowerMod isEqualToString:@"cmd"] ||
                           [lowerMod isEqualToString:@"command"]) {
                    modifierMask |= NSCommandKeyMask;
                }
                NSDebugLog(@"DBusMenuShortcutParser: GTK format modifier '<%@>' -> mask %lu", 
                      modName, (unsigned long)modifierMask);
                
                // Remove the <...> from the working string
                work = [work stringByReplacingCharactersInRange:NSMakeRange(openRange.location, 
                                                    closeRange.location - openRange.location + 1)
                                                    withString:@""];
            } else {
                break;
            }
        }
        
        // Whatever remains is the key
        key = [self normalizeKeyName:work];
        NSDebugLog(@"DBusMenuShortcutParser: GTK format key: '%@' -> '%@'", work, key);
    } else {
        // Standard '+' separated format (e.g. "Ctrl+T", "control+shift+x", "ctrl+alt+t")
        // Also handle "Control_L+Shift_L+T" etc.
        NSArray *parts = [keyCombo componentsSeparatedByString:@"+"];
        
        for (NSString *part in parts) {
            NSString *cleanPart = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSDebugLog(@"DBusMenuShortcutParser: Processing key combo part: '%@'", cleanPart);
            
            // Case-insensitive modifier matching for Canonical AppMenu compatibility
            // Also handle "_L" and "_R" suffix variants (e.g. "Control_L", "Shift_R")
            NSString *lowerPart = [cleanPart lowercaseString];
            NSString *lowerBase = lowerPart;
            
            // Strip _L / _R suffix for modifier matching
            if ([lowerPart hasSuffix:@"_l"] || [lowerPart hasSuffix:@"_r"]) {
                lowerBase = [lowerPart substringToIndex:[lowerPart length] - 2];
            }
            
            if ([lowerBase isEqualToString:@"cmd"] || [lowerBase isEqualToString:@"command"] ||
                [lowerBase isEqualToString:@"super"] || [lowerBase isEqualToString:@"meta"] ||
                [lowerBase isEqualToString:@"hyper"]) {
                modifierMask |= NSCommandKeyMask;
                NSDebugLog(@"DBusMenuShortcutParser: Added Command modifier mask (from '%@')", cleanPart);
            } else if ([lowerBase isEqualToString:@"shift"]) {
                modifierMask |= NSShiftKeyMask;
                NSDebugLog(@"DBusMenuShortcutParser: Added Shift modifier mask (from '%@')", cleanPart);
            } else if ([lowerBase isEqualToString:@"alt"] || [lowerBase isEqualToString:@"option"]) {
                modifierMask |= NSAlternateKeyMask;
                NSDebugLog(@"DBusMenuShortcutParser: Added Alt modifier mask (from '%@')", cleanPart);
            } else if ([lowerBase isEqualToString:@"ctrl"] || [lowerBase isEqualToString:@"control"]) {
                modifierMask |= NSControlKeyMask;
                NSDebugLog(@"DBusMenuShortcutParser: Added Control modifier mask (from '%@')", cleanPart);
            } else {
                // This should be the key
                key = [self normalizeKeyName:cleanPart];
                NSDebugLog(@"DBusMenuShortcutParser: Set key equivalent: '%@' (from '%@')", key, cleanPart);
            }
        }
    }
    
    NSDebugLog(@"DBusMenuShortcutParser: Key combo result - key: '%@', modifiers: %lu", key, (unsigned long)modifierMask);
    return @{@"key": key, @"modifiers": @(modifierMask)};
}

+ (NSString *)normalizeKeyName:(NSString *)keyName
{
    if (!keyName || [keyName length] == 0) {
        return @"";
    }
    
    // Normalise to lowercase for case-insensitive matching
    NSString *normalized = [keyName lowercaseString];
    
    // Handle special keys - also check common GTK-X11 keysym names
    if ([normalized isEqualToString:@"return"] || [normalized isEqualToString:@"enter"] ||
        [normalized isEqualToString:@"kp_enter"]) {
        return @"\r";
    } else if ([normalized isEqualToString:@"tab"] || [normalized isEqualToString:@"kpad_tab"]) {
        return @"\t";
    } else if ([normalized isEqualToString:@"space"] || [normalized isEqualToString:@"kpad_space"]) {
        return @" ";
    } else if ([normalized isEqualToString:@"escape"] || [normalized isEqualToString:@"esc"]) {
        return @"\033";
    } else if ([normalized isEqualToString:@"backspace"] || [normalized isEqualToString:@"back_space"] ||
               [normalized isEqualToString:@"back"]) {
        return @"\b";
    } else if ([normalized isEqualToString:@"delete"] || [normalized isEqualToString:@"delete_key"]) {
        return @"\177";
    } else if ([normalized isEqualToString:@"page_up"] || [normalized isEqualToString:@"prior"]) {
        return @"\x7f";
    } else if ([normalized isEqualToString:@"page_down"] || [normalized isEqualToString:@"next"]) {
        return @"\x7f";
    } else if ([normalized isEqualToString:@"home"]) {
        return @"\x7f";
    } else if ([normalized isEqualToString:@"end"]) {
        return @"\x7f";
    } else if ([normalized hasPrefix:@"f"] && [normalized length] >= 2 && [normalized length] <= 4 &&
               [normalized characterAtIndex:1] >= '0' && [normalized characterAtIndex:1] <= '9') {
        // Function keys F1-F24 - return as is
        // GTK may send "F1" or "f1", and we preserve the lowercase format
        return normalized;
    }
    
    // Single character - ensure lowercase
    if ([normalized length] == 1) {
        unichar c = [normalized characterAtIndex:0];
        if (c >= 'A' && c <= 'Z') {
            c = c - 'A' + 'a';
        }
        return [NSString stringWithCharacters:&c length:1];
    }
    
    // Multi-character key names that aren't special keys.
    // Many GTK apps send keysym names like "KP_Add", "minus", "equal", "bracketleft" etc.
    // Try to map these to their single-character equivalents.
    static NSDictionary *keySymToCharMap = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keySymToCharMap = @{
            @"minus": @"-",
            @"equal": @"=",
            @"bracketleft": @"[",
            @"bracketright": @"]",
            @"semicolon": @";",
            @"apostrophe": @"'",
            @"comma": @",",
            @"period": @".",
            @"slash": @"/",
            @"backslash": @"\\",
            @"grave": @"`",
            @"asciitilde": @"~",
            @"exclam": @"!",
            @"at": @"@",
            @"numbersign": @"#",
            @"dollar": @"$",
            @"percent": @"%%",
            @"asciicircum": @"^",
            @"ampersand": @"&",
            @"asterisk": @"*",
            @"parenleft": @"(",
            @"parenright": @")",
            @"underscore": @"_",
            @"plus": @"+",
            @"braceleft": @"{",
            @"braceright": @"}",
            @"colon": @":",
            @"quotedbl": @"\"",
            @"less": @"<",
            @"greater": @">",
            @"question": @"?",
            @"bar": @"|",
            @"kpad_add": @"+",
            @"kpad_subtract": @"-",
            @"kpad_multiply": @"*",
            @"kpad_divide": @"/",
            @"kpad_0": @"0",
            @"kpad_1": @"1",
            @"kpad_2": @"2",
            @"kpad_3": @"3",
            @"kpad_4": @"4",
            @"kpad_5": @"5",
            @"kpad_6": @"6",
            @"kpad_7": @"7",
            @"kpad_8": @"8",
            @"kpad_9": @"9",
        };
    });
    
    NSString *mapped = [keySymToCharMap objectForKey:normalized];
    if (mapped) {
        return mapped;
    }
    
    // Last resort: if it looks like a multi-character keysym name, try to
    // extract a single character by checking if X11 can translate it
    if ([normalized length] > 1) {
        // Try XStringToKeysym then back to character - only for ASCII printable
        KeySym sym = XStringToKeysym([normalized UTF8String]);
        if (sym != NoSymbol && sym >= 0x20 && sym <= 0x7E) {
            unichar c = (unichar)sym;
            return [NSString stringWithCharacters:&c length:1];
        }
        // Fall back to first character
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
