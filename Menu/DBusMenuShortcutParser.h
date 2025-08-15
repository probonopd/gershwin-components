#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface DBusMenuShortcutParser : NSObject

// Parse shortcut array from DBus menu properties
+ (NSString *)parseShortcutArray:(NSArray *)shortcutArray;

// Parse key combination string into key and modifiers
+ (NSDictionary *)parseKeyCombo:(NSString *)keyCombo;

// Normalize key names for NSMenuItem
+ (NSString *)normalizeKeyName:(NSString *)keyName;

// Convert modifier mask to string representation
+ (NSString *)modifierMaskToString:(NSUInteger)modifierMask;

// Test method for shortcut parsing (exposed for testing)
+ (NSDictionary *)testParseKeyCombo:(NSString *)keyCombo;

@end
