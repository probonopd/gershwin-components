#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "MenuApplication.h"
#import "MenuController.h"

int main(int argc, char *argv[])
{
    NSLog(@"Menu.app: Starting application initialization...");
    
    // Use NSApplicationMain to properly initialize GNUstep
    return NSApplicationMain(argc, (const char **)argv);
}
