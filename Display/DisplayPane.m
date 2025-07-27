// Copyright (c) 2025, Simon Peter
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

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
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 
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
    // Initialize the display controller data
    [displayController refreshDisplays:nil];
    
    // Signal that the pane is ready
    [self setInitialKeyView:nil];
}

- (void)didSelect
{
    [super didSelect];
    // Refresh data when the pane is selected but don't start polling
    [displayController refreshDisplays:nil];
    
    // Ensure the pane is in a valid state for SystemPreferences
    [self setInitialKeyView:nil];
}

- (void)willUnselect
{
    // Called before the pane is deselected - return reply when done
    NSLog(@"DisplayPane: willUnselect called");
}

- (void)didUnselect
{
    [super didUnselect];
    // No polling to stop anymore
    NSLog(@"DisplayPane: didUnselect called");
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    // Allow the pane to be unselected
    NSLog(@"DisplayPane: shouldUnselect called, allowing unselect");
    return NSUnselectNow;
}

- (void)replyToShouldUnselect:(BOOL)shouldUnselect
{
    // This method should be called if we need async validation
    NSLog(@"DisplayPane: replyToShouldUnselect called with reply: %s", shouldUnselect ? "YES" : "NO");
    // Call super to complete the reply
    [super replyToShouldUnselect:shouldUnselect];
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

@end
