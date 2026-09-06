#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "CLMController.h"

@interface CLMApplicationDelegate : NSObject <NSApplicationDelegate>
@end

@implementation CLMApplicationDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    NSDebugLLog(@"gwcomp", @"CreateLiveMediaAssistant: Last window closed, terminating application");
    return YES;
}
@end

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSDebugLLog(@"gwcomp", @"CreateLiveMediaAssistant: main() starting (uid=%d)", getuid());

        NSApplication *app = [NSApplication sharedApplication];

        // Load and set application icon
        NSImage *appIcon = nil;
        NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"Create_Live_Media"
                                                             ofType:@"png"];
        if (!iconPath && argv[0]) {
            NSString *exeDir = [[NSString stringWithUTF8String:argv[0]]
                stringByDeletingLastPathComponent];
            if ([exeDir length] > 0) {
                iconPath = [exeDir stringByAppendingPathComponent:
                    @"Resources/Create_Live_Media.png"];
            }
        }
        if (iconPath) {
            appIcon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        }
        if (appIcon) {
            [app setApplicationIconImage:appIcon];
            [appIcon setName:@"Create_Live_Media"];
        }

        CLMApplicationDelegate *appDelegate = [[CLMApplicationDelegate alloc] init];
        [app setDelegate:appDelegate];

        CLMController *controller = [[CLMController alloc] init];
        [controller showAssistant];

        [app run];
    }

    NSDebugLLog(@"gwcomp", @"CreateLiveMediaAssistant: main() exiting");
    return 0;
}
