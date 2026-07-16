/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DisplayPane.h"
#import "DisplayController.h"

@implementation DisplayPane

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        displayController = [[DisplayController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self stopRefreshTimer];
    [displayController release];
    [super dealloc];
}

- (void)startRefreshTimer
{
    if (!refreshTimer) {
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 
                                                        target:displayController 
                                                      selector:@selector(refreshDisplays:) 
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
    if (!_mainView) {
        _mainView = [[displayController createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil; // We create the view programmatically
}

- (void)mainViewDidLoad
{
    // createMainView already triggers an initial refreshDisplays:,
    // so do not call it again here.
    [self setInitialKeyView:nil];
}

- (void)didSelect
{
    [super didSelect];
    // Refresh display data when the pane is (re-)selected
    [displayController refreshDisplays:nil];
    // Start polling so hot-plugged monitors are detected while the pane is open
    [self startRefreshTimer];
    [self setInitialKeyView:nil];
}

- (void)willUnselect
{
    // Called before the pane is deselected - return reply when done
    NSDebugLog(@"DisplayPane: willUnselect called");
}

- (void)didUnselect
{
    [super didUnselect];
    // Stop polling when the pane is no longer visible
    [self stopRefreshTimer];
    NSDebugLog(@"DisplayPane: didUnselect called");
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    // Allow the pane to be unselected
    NSDebugLog(@"DisplayPane: shouldUnselect called, allowing unselect");
    return NSUnselectNow;
}

- (void)replyToShouldUnselect:(BOOL)shouldUnselect
{
    // This method should be called if we need async validation
    NSDebugLog(@"DisplayPane: replyToShouldUnselect called with reply: %s", shouldUnselect ? "YES" : "NO");
    // Call super to complete the reply
    [super replyToShouldUnselect:shouldUnselect];
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

@end
