#import "MenuApplication.h"
#import "X11ShortcutManager.h"
#import "DBusMenuParser.h"

@implementation MenuApplication

- (void)sendEvent:(NSEvent *)event
{
    // Log events for debugging if needed
    NSEventType eventType = [event type];
    if (eventType == NSKeyDown || eventType == NSMouseMoved) {
        // Suppress frequent event logging
    } else {
        NSLog(@"MenuApplication: Processing event type %ld", (long)eventType);
    }
    
    [super sendEvent:event];
}

- (void)terminate:(id)sender
{
    NSLog(@"MenuApplication: Application terminating");
    
    // Ensure global shortcuts are cleaned up before termination
    NSLog(@"MenuApplication: Cleaning up global shortcuts...");
    [[X11ShortcutManager sharedManager] cleanup];
    [DBusMenuParser cleanup];
    
    [super terminate:sender];
}

@end
