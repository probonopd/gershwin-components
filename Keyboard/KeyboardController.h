/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <AppKit/AppKit.h>

@interface KeyboardController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
{
    NSView *mainView;
    NSBox *keyboardTypeBox;
    NSTableView *layoutTable;
    NSTableView *variantTable;
    NSScrollView *layoutScroll;
    NSScrollView *variantScroll;
    NSTextField *statusLabel;
    NSTextField *tryTextField;
    NSButton *isAppleKeyboardCheckbox;
    NSPopUpButton *keyboardTypePopup;

    NSDictionary *layouts;
    NSDictionary *variantsByLayout;
    NSString *setxkbmapPath;

    NSArray *sortedLayouts;
    NSArray *currentVariants;

    NSString *lastAppliedLayout;
    NSString *lastAppliedVariant;
    NSString *lastAppliedKeyboardType;

    BOOL metadataLoaded;
    BOOL isRefreshing;
}

- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)refreshFromSystem;
- (IBAction)applySelection:(id)sender;
- (IBAction)isAppleKeyboardCheckboxChanged:(id)sender;
- (IBAction)keyboardTypeChanged:(id)sender;

@end
