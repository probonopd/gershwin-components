#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "LoginWindow.h"

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    [NSApplication sharedApplication];
    [NSApp setDelegate: [[LoginWindow alloc] init]];
    [NSApp run];
    
    [pool drain];
    return 0;
}
