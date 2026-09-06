/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MenuPrefPane.h"
#import "MenuControllerPrefPane.h"

@implementation MenuPrefPane

+ (BOOL)isCompatible { return YES; }

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        _controller = nil;
    }
    return self;
}

- (void)dealloc
{
    [_controller release];
    [super dealloc];
}

- (NSView *)loadMainView
{
    if (_mainView == nil) {
        if (_controller == nil) {
            _controller = [[MenuControllerPrefPane alloc] init];
        }
        _mainView = [[_controller createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil;
}

- (void)mainViewDidLoad
{
    [_controller refreshExtras];
    [self setInitialKeyView:nil];
}

- (void)didSelect
{
    [super didSelect];
    [_controller refreshExtras];
    [self setInitialKeyView:nil];
}

- (void)didUnselect
{
    [super didUnselect];
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    return NSUnselectNow;
}

@end
