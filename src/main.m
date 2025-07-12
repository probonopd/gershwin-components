#import <AppKit/AppKit.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSApplication *app = [NSApplication sharedApplication];
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [app setDelegate:delegate];
    
    [app run];
    
    [pool drain];
    return 0;
}