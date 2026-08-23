/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Pane container for hand-laid-out operation tabs. NSTabView resizes the
// selected item's view whenever the window changes, and GNUstep installs
// tab views with setFrame: (bypassing setFrameSize:), so pure autoresizing
// masks are not enough for forms whose rows are computed top-down. This
// subclass notifies a layout owner on every size change and once when the
// view lands in its final hierarchy, letting each pane controller re-run
// its layout against the real content rect.
@interface DUPaneView : NSView

// Weak; typically the owning pane controller.
@property (nonatomic, weak) id layoutOwner;

// No-argument selector invoked on the owner (e.g. @selector(relayout)).
@property (nonatomic, assign) SEL layoutSelector;

@end
