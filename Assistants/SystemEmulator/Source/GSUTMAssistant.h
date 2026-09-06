#import <Foundation/Foundation.h>

@class GSUTMConfiguration;
@class GSUTMMainWindowController;

@interface GSUTMAssistant : NSObject

- (instancetype)initWithOwner:(GSUTMMainWindowController *)owner;
- (void)runNewVMAssistant;
- (void)editConfiguration:(GSUTMConfiguration *)config;

@end
