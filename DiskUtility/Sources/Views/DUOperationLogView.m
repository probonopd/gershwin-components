/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperationLogView.h"

#import "AppearanceMetrics.h"

@implementation DUOperationLogView {
    NSTextView *_textView;
}

- (instancetype)init
{
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _scrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, 100)];
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = NO;
    _scrollView.borderType = NSBezelBorder;
    _scrollView.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;

    NSTextView *textView = [[NSTextView alloc]
        initWithFrame:NSMakeRect(0, 0,
                                  _scrollView.contentSize.width,
                                  _scrollView.contentSize.height)];
    textView.editable = NO;
    textView.richText = NO;
    textView.verticallyResizable = YES;
    // Lines wrap instead of widening the container; a horizontal scrollbar
    // would fight the wrapping behavior expected of the log pane.
    textView.horizontallyResizable = NO;
    // Natural theme background for the log pane.
    textView.textContainerInset =
        NSMakeSize(METRICS_SPACE_8, METRICS_SPACE_8);
    textView.font = [NSFont userFixedPitchFontOfSize:11.0];

    _textView = textView;
    _scrollView.documentView = textView;
    return self;
}

- (void)appendLine:(NSString *)line
{
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(appendLine:)
                               withObject:line
                            waitUntilDone:NO];
        return;
    }
    NSString *text =
        line == nil ? @"" : [line stringByReplacingOccurrencesOfString:
                                       @"\r" withString:@""];
    if (text.length == 0) {
        return;
    }

    NSTextStorage *storage = _textView.textStorage;
    NSDictionary *attributes = @{
        NSFontAttributeName : [NSFont userFixedPitchFontOfSize:11.0],
    };
    NSAttributedString *appended =
        [[NSAttributedString alloc]
            initWithString:[text stringByAppendingString:@"\n"]
                attributes:attributes];

    // Scroll only when the user is already at the bottom; jumping while
    // they scroll back through history would be hostile.
    BOOL atEnd = NSMaxRange(_textView.selectedRange) >= storage.length;
    [storage appendAttributedString:appended];
    if (atEnd) {
        [_textView scrollRangeToVisible:NSMakeRange(storage.length, 0)];
    }
}

- (void)clear
{
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(clear)
                               withObject:nil
                            waitUntilDone:NO];
        return;
    }
    _textView.string = @"";
}

@end
