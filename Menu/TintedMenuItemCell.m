/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TintedMenuItemCell.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSMutableDictionary *_tintCache = nil;
static const char kOriginalImageKey;

static NSImage *_tintedImage(NSImage *image)
{
    if (!_tintCache) {
        _tintCache = [[NSMutableDictionary alloc] init];
    }

    NSString *name = [image name];
    if (!name) return image;
    NSImage *cached = [_tintCache objectForKey:name];
    if (cached) return cached;

    NSColor *tintColor = [NSColor selectedMenuItemTextColor];
    if (!tintColor) tintColor = [NSColor whiteColor];

    NSSize size = [image size];
    NSImage *tinted = [[NSImage alloc] initWithSize:size];
    [tinted lockFocus];
    [image drawAtPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositeCopy fraction:1.0];
    [tintColor set];
    NSRectFillUsingOperation(NSMakeRect(0, 0, size.width, size.height), NSCompositeSourceAtop);
    [tinted unlockFocus];

    [_tintCache setObject:tinted forKey:name];
    return tinted;
}

@implementation NSMenuItemCell (TintedIcons)

- (void)drawImage:(NSImage *)image
        withFrame:(NSRect)cellFrame
           inView:(NSView *)controlView
{
    if (image && [self isHighlighted]) {
        image = _tintedImage(image);
    }
    [super drawImage:image withFrame:cellFrame inView:controlView];
}

- (void)tinted_setHighlighted:(BOOL)flag
{
    BOOL was = [self isHighlighted];
    [self tinted_setHighlighted:flag];

    if (flag == was) return;

    NSMenuItem *item = [self menuItem];
    NSImage *image = [item image];
    NSString *title = [item title];
    if (!image) return;

    if (flag && (!title || [title length] == 0)) {
        objc_setAssociatedObject(item, &kOriginalImageKey,
                                 image, OBJC_ASSOCIATION_RETAIN);
        [item setImage:_tintedImage(image)];
    } else if (!flag) {
        NSImage *orig = objc_getAssociatedObject(item, &kOriginalImageKey);
        if (orig) {
            [item setImage:orig];
            objc_setAssociatedObject(item, &kOriginalImageKey, nil, OBJC_ASSOCIATION_RETAIN);
        }
    }
}

@end

__attribute__((constructor))
static void initTintedMenuSwizzling(void)
{
    Class cls = objc_getClass("NSMenuItemCell");
    if (!cls) return;

    SEL sel = sel_registerName("setHighlighted:");
    SEL tintedSel = sel_registerName("tinted_setHighlighted:");

    Method origMethod = class_getInstanceMethod(cls, sel);
    Method tintedMethod = class_getInstanceMethod(cls, tintedSel);
    if (!origMethod || !tintedMethod) return;

    IMP origIMP = method_getImplementation(origMethod);
    IMP tintedIMP = method_getImplementation(tintedMethod);
    if (origIMP == tintedIMP) return;

    method_exchangeImplementations(origMethod, tintedMethod);
}
