#import <Foundation/Foundation.h>

@interface MenuUtils : NSObject

+ (NSString *)getApplicationNameForWindow:(unsigned long)windowId;
+ (BOOL)isWindowValid:(unsigned long)windowId;
+ (NSArray *)getAllWindows;
+ (unsigned long)getActiveWindow;
+ (NSString *)getWindowProperty:(unsigned long)windowId atomName:(NSString *)atomName;
+ (NSString*)getWindowMenuService:(unsigned long)windowId;
+ (NSString*)getWindowMenuPath:(unsigned long)windowId;
+ (BOOL)setWindowMenuService:(NSString*)service path:(NSString*)path forWindow:(unsigned long)windowId;
+ (BOOL)advertiseGlobalMenuSupport;
+ (void)removeGlobalMenuSupport;

@end
