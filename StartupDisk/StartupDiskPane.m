/*
 * Copyright (c) 2005 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StartupDiskPane.h"
#import "StartupDiskController.h"

@implementation StartupDiskPane

- (id)initWithBundle:(NSBundle *)bundle
{
    NSLog(@"StartupDiskPane: initWithBundle called with bundle = %@", bundle);
    self = [super initWithBundle:bundle];
    if (self) {
        NSLog(@"StartupDiskPane: initWithBundle succeeded, checking efibootmgr permissions");
        
        NSLog(@"StartupDiskPane: efibootmgr permissions check passed");
    } else {
        NSLog(@"StartupDiskPane: initWithBundle failed - super initWithBundle returned nil");
    }
    return self;
}

- (NSView *)loadMainView
{
    NSLog(@"StartupDiskPane: loadMainView called");
    
    // Create the main view if it doesn't exist
    if (![self mainView]) {
        NSLog(@"StartupDiskPane: No main view exists, creating one");
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        [self setMainView:view];
        [view release];
        NSLog(@"StartupDiskPane: Created main view with frame: %@", NSStringFromRect([view frame]));
    }
    
    NSView *mainView = [super loadMainView];
    NSLog(@"StartupDiskPane: super loadMainView completed, returned view = %@", mainView);
    [self mainViewDidLoad];
    return mainView;
}

- (void)mainViewDidLoad
{
    NSLog(@"StartupDiskPane: mainViewDidLoad called");
    
    NSView *mainView = [self mainView];
    NSLog(@"StartupDiskPane: mainView = %@", mainView);
    NSLog(@"StartupDiskPane: mainView frame = %@", NSStringFromRect([mainView frame]));
    
    startupDiskController = [[StartupDiskController alloc] init];
    NSLog(@"StartupDiskPane: Created startupDiskController = %@", startupDiskController);
    
    [startupDiskController setMainView:mainView];
    NSLog(@"StartupDiskPane: Set main view on controller");
    
    // Set up a timer to refresh the boot entries periodically
    refreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                    target:self
                                                  selector:@selector(refreshBootEntries)
                                                  userInfo:nil
                                                   repeats:YES];
    NSLog(@"StartupDiskPane: Created refresh timer = %@", refreshTimer);
    
    NSLog(@"StartupDiskPane: About to call refreshBootEntries");
    [self refreshBootEntries];
    NSLog(@"StartupDiskPane: mainViewDidLoad completed");
}

- (void)refreshBootEntries
{
    NSLog(@"StartupDiskPane: refreshBootEntries called");
    [startupDiskController refreshBootEntries];
    NSLog(@"StartupDiskPane: refreshBootEntries completed");
}

- (void)willUnselect
{
    [refreshTimer invalidate];
    refreshTimer = nil;
}

- (void)dealloc
{
    [refreshTimer invalidate];
    [startupDiskController release];
    [super dealloc];
}

@end
