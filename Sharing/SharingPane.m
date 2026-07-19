/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Sharing Preference Pane Implementation
 */

#import "SharingPane.h"
#import "SharingController.h"

@implementation SharingPane

+ (BOOL)isCompatible { return YES; }

- (id)initWithBundle:(NSBundle *)bundle
{
    NSDebugLog(@"SharingPane: initWithBundle starting");
    self = [super initWithBundle:bundle];
    if (self) {
        NSDebugLog(@"SharingPane: super init successful");
        controller = nil;  // Create lazily when needed
        refreshTimer = nil;
        NSDebugLog(@"SharingPane: initWithBundle complete");
    }
    return self;
}

- (void)dealloc
{
    [self stopRefreshTimer];
    [controller release];
    [super dealloc];
}

- (void)startRefreshTimer
{
    if (!refreshTimer) {
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                        target:controller
                                                      selector:@selector(refreshStatus:)
                                                      userInfo:nil
                                                       repeats:YES];
        [refreshTimer retain];
    }
}

- (void)stopRefreshTimer
{
    if (refreshTimer) {
        [refreshTimer invalidate];
        [refreshTimer release];
        refreshTimer = nil;
    }
}

- (NSView *)loadMainView
{
    NSDebugLog(@"SharingPane: loadMainView called");
    if (_mainView == nil) {
        // Create controller lazily when view is first needed
        if (controller == nil) {
            NSDebugLog(@"SharingPane: Creating SharingController");
            controller = [[SharingController alloc] init];
            NSDebugLog(@"SharingPane: SharingController created");
        }
        NSDebugLog(@"SharingPane: Creating main view");
        _mainView = [[controller createMainView] retain];
        NSDebugLog(@"SharingPane: Main view created");
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil; // We create the view programmatically
}

- (void)mainViewDidLoad
{
    // Initial data refresh
    [controller refreshStatus:nil];
    [self setInitialKeyView:nil];
}

- (void)didSelect
{
    [super didSelect];
    // Refresh data when the pane is selected
    [controller refreshStatus:nil];
    [self startRefreshTimer];
    [self setInitialKeyView:nil];
}

- (void)willUnselect
{
}

- (void)didUnselect
{
    [super didUnselect];
    [self stopRefreshTimer];
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    return NSUnselectNow;
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

@end
