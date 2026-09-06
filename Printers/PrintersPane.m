/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PrintersPane.h"
#import "PrintersController.h"
#include <cups/cups.h>

@implementation PrintersPane

+ (BOOL)isCompatible {
    /* The pane needs a running CUPS daemon (it talks to cupsd over IPP).
       Connect to the CUPS server; anything but a working connection means
       the pane cannot operate. */
    http_t *http = httpConnect2(cupsServer(), ippPort(), NULL, AF_UNSPEC,
                                cupsEncryption(), 1, 30000, NULL);
    if (http) {
        httpClose(http);
        return YES;
    }
    return NO;
}

+ (NSString *)compatibilityReason {
    return @"CUPS printing service not available — the cupsd daemon must be running";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        controller = [[PrintersController alloc] init];
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
                                                      selector:@selector(refreshPrinters:)
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
    if (_mainView == nil) {
        _mainView = [[controller createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil;
}

- (void)mainViewDidLoad
{
    [controller refreshPrinters:nil];
    [controller showPrivilegeWarningIfNeeded];
    [self setInitialKeyView:nil];
}

- (void)didSelect
{
    [super didSelect];
    [controller refreshPrinters:nil];
    [self setInitialKeyView:nil];
}

- (void)willUnselect
{
    NSDebugLLog(@"gwcomp", @"PrintersPane: willUnselect called");
}

- (void)didUnselect
{
    [super didUnselect];
    [self stopRefreshTimer];
    NSDebugLLog(@"gwcomp", @"PrintersPane: didUnselect called");
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    NSDebugLLog(@"gwcomp", @"PrintersPane: shouldUnselect called, allowing unselect");
    return NSUnselectNow;
}

@end
