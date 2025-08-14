#import "MenuApplication.h"

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
    [super terminate:sender];
}

@end
