#import <AppKit/AppKit.h>
#import "GSUTMAppDelegate.h"

int main(int argc, const char *argv[])
{
    CREATE_AUTORELEASE_POOL(pool);
    [NSApplication sharedApplication];
    GSUTMAppDelegate *delegate = [[GSUTMAppDelegate alloc] init];
    [NSApp setDelegate:delegate];
    if (argc > 1) {
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            delegate.pendingOpenPath = path;
        }
    }
    RELEASE(pool);
    return NSApplicationMain(argc, argv);
}
