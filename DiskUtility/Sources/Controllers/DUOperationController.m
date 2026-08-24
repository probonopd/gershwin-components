/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperationController.h"

#import "DUEraseViewController.h"
#import "DUFirstAidViewController.h"
#import "DUOperationLogView.h"
#import "DUPartitionViewController.h"
#import "DURestoreViewController.h"
#import "AppearanceMetrics.h"
#import "DUStorageCapabilities.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"

static NSString * const kTabIdentifierFirstAid = @"firstaid";
static NSString * const kTabIdentifierErase = @"erase";
static NSString * const kTabIdentifierPartition = @"partition";
static NSString * const kTabIdentifierRAID = @"raid";
static NSString * const kTabIdentifierRestore = @"restore";

@interface DUOperationController () <NSTabViewDelegate>
@property (nonatomic, strong, readwrite) NSTabView *tabView;
@property (nonatomic, strong, readwrite) DUOperationLogView *logView;
@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong) NSView *raidPane;
@property (nonatomic, strong) DUFirstAidViewController *firstAidPane_;
@property (nonatomic, strong) DUEraseViewController *erasePane_;
@property (nonatomic, strong) DUPartitionViewController *partitionPane_;
@property (nonatomic, strong) DURestoreViewController *restorePane_;
@property (nonatomic, strong) NSView *unavailablePlaceholder;
@end

@implementation DUOperationController

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
{
    NSParameterAssert(manager != nil);
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _storageManager = manager;

    _logView = [[DUOperationLogView alloc] init];

    _tabView = [[NSTabView alloc]
        initWithFrame:NSMakeRect(0, 0, 400, 300)];
    _tabView.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    _tabView.delegate = self;

    _firstAidPane_ =
        [[DUFirstAidViewController alloc]
            initWithStorageManager:manager logView:_logView];
    _erasePane_ =
        [[DUEraseViewController alloc]
            initWithStorageManager:manager logView:_logView];
    _partitionPane_ =
        [[DUPartitionViewController alloc]
            initWithStorageManager:manager logView:_logView];
    _restorePane_ =
        [[DURestoreViewController alloc]
            initWithStorageManager:manager logView:_logView];

    // Shared placeholder shown in any tab whose operation is unavailable
    // for the current selection (SPEC section 30).
    _unavailablePlaceholder = [self placeholderView];

    [self addTabWithIdentifier:kTabIdentifierFirstAid
                         label:NSLocalizedString(@"First Aid", nil)
                          view:_firstAidPane_.view];
    [self addTabWithIdentifier:kTabIdentifierErase
                         label:NSLocalizedString(@"Erase", nil)
                          view:_erasePane_.view];
    [self addTabWithIdentifier:kTabIdentifierPartition
                         label:NSLocalizedString(@"Partition", nil)
                          view:_partitionPane_.view];
    [self addTabWithIdentifier:kTabIdentifierRAID
                         label:NSLocalizedString(@"RAID", nil)
                          view:self.raidPaneView];
    [self addTabWithIdentifier:kTabIdentifierRestore
                         label:NSLocalizedString(@"Restore", nil)
                          view:_restorePane_.view];
    return self;
}

- (NSView *)placeholderView
{
    NSView *view =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 260)];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.editable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.stringValue = NSLocalizedString(
        @"This operation is not available for the current selection.", nil);
    label.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [(NSCell *)label.cell setWraps:YES];
    label.textColor = [NSColor secondarySelectedControlColor];
    label.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                   NSHeight(view.frame) / 2.0,
                   NSWidth(view.frame) - 2 * METRICS_CONTENT_SIDE_MARGIN,
                   30);
    label.autoresizingMask =
        NSViewWidthSizable | NSViewMinYMargin;
    [view addSubview:label];
    return view;
}

- (void)addTabWithIdentifier:(NSString *)identifier
                       label:(NSString *)label
                        view:(NSView *)view
{
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:identifier];
    item.label = label;

    // Tab-content sizing trap: panes are built against placeholder frames;
    // sizing them to the real content rect BEFORE installation lets their
    // top-down row math land correctly, and DUPaneView keeps them correct
    // across later resizes.
    NSRect contentRect = [self.tabView contentRect];
    view.frame = NSMakeRect(0, 0, contentRect.size.width,
                            contentRect.size.height);
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    item.view = view;
    [_tabView addTabViewItem:item];
}

- (NSTabViewItem *)itemForIdentifier:(NSString *)identifier
{
    NSInteger index = [self.tabView indexOfTabViewItemWithIdentifier:identifier];
    return index != NSNotFound && index >= 0
        ? [self.tabView tabViewItemAtIndex:index]
        : nil;
}

- (void)refreshForObject:(DUStorageObject *)object
             capabilities:(DUStorageCapabilities *)capabilities
{
    // Availability follows SPEC section 30: unsupported tabs swap in a
    // placeholder because GNUstep tab items cannot be disabled individually.
    void (^set)(NSString *, BOOL, NSView *) =
        ^(NSString *tabIdentifier, BOOL available, NSView *realView) {
            NSInteger index =
                [self.tabView indexOfTabViewItemWithIdentifier:tabIdentifier];
            if (index == NSNotFound || index < 0) {
                return;
            }
            NSTabViewItem *item = [self.tabView tabViewItemAtIndex:index];
            NSView *wanted =
                (available && object != nil) ? realView
                                             : self.unavailablePlaceholder;
            if (item.view != wanted) {
                item.view = wanted;
            }
        };

    set(kTabIdentifierFirstAid,
        capabilities.canVerify || capabilities.canRepair ||
            capabilities.canRepairPermissions,
        _firstAidPane_.view);
    set(kTabIdentifierErase, capabilities.canErase, _erasePane_.view);
    set(kTabIdentifierRestore, capabilities.canRestore,
        _restorePane_.view);
    set(kTabIdentifierRAID, capabilities.canCreateRAID,
        self.raidPaneView);

    /* Partitioning always targets a whole device. When the selection is one
     * of its volumes or partitions, walk up to the owning device so its
     * Partition tab shows the parent disk's map (the apply path warns that
     * the whole disk is rewritten). Devices themselves pass through; RAID
     * sets have no device ancestor and stay on the placeholder. */
    DUStorageObject *partitionTarget = object;
    while (partitionTarget != nil &&
           partitionTarget.type != DUStorageObjectTypeDevice) {
        partitionTarget = partitionTarget.parent;
    }
    BOOL canPartitionTarget =
        partitionTarget != nil && partitionTarget.capabilities.canPartition;
    set(kTabIdentifierPartition, canPartitionTarget, _partitionPane_.view);

    [_firstAidPane_ refreshForObject:object capabilities:capabilities];
    [_erasePane_ refreshForObject:object capabilities:capabilities];
    if (canPartitionTarget) {
        [_partitionPane_ refreshForObject:(DUStorageObject *)partitionTarget
                             capabilities:partitionTarget.capabilities];
    } else {
        // Clears the pane so a stale disk never lingers behind the tab.
        [_partitionPane_ refreshForObject:nil capabilities:nil];
    }
    [_restorePane_ refreshForObject:object capabilities:capabilities];
}

- (void)setControlsEnabled:(BOOL)enabled
{
    [_firstAidPane_ setControlsEnabled:enabled];
    [_erasePane_ setControlsEnabled:enabled];
    [_partitionPane_ setControlsEnabled:enabled];
    [_restorePane_ setControlsEnabled:enabled];
}

- (id)firstAidPane
{
    return _firstAidPane_;
}

- (id)erasePane
{
    return _erasePane_;
}

- (id)restorePane
{
    return _restorePane_;
}

// Current pane views; registered by later waves, placeholders before.
- (NSView *)raidPaneView
{
    return _raidPane ?: _unavailablePlaceholder;
}

#pragma mark - NSTabViewDelegate

// Tab swaps leave 1px-stale text in regions the backend does not damage
// (observed as double-struck labels in unrelated panes); one synchronous
// full-window redraw after each selection heals them.
- (void)tabView:(NSTabView *)tabView
    didSelectTabViewItem:(NSTabViewItem *)item
{
    (void)item;
    NSWindow *window = tabView.window;
    if (window != nil) {
        [[window contentView] setNeedsDisplay:YES];
        [window display];
    }
}

@end
