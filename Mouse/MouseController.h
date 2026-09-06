/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface MouseController : NSObject
{
    NSView *mainView;
    NSBox *mouseBox;
    NSBox *trackpadBox;
    NSBox *trackpointBox;

    NSSlider *mouseSpeedSlider;
    NSTextField *mouseSpeedLabel;

    NSSlider *trackpadSpeedSlider;
    NSTextField *trackpadSpeedLabel;

    NSSlider *trackpointSpeedSlider;
    NSTextField *trackpointSpeedLabel;

    NSButton *naturalScrollingCheckbox;
    NSButton *tapToClickCheckbox;
    NSButton *twoFingerRightClickCheckbox;
    NSButton *threeFingerMiddleClickCheckbox;
    NSButton *disableWhileTypingCheckbox;
    NSButton *leftHandedCheckbox;

    NSTextField *statusLabel;

    NSString *xinputPath;
    NSString *touchpadName;
    NSString *mouseName;
    NSString *trackpointName;

    BOOL isRefreshing;
}

- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)refreshFromSystem;
- (IBAction)settingChanged:(id)sender;

@end
