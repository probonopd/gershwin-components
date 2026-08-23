/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperationController.h"

#import "DUEraseViewController.h"
#import "DUFirstAidViewController.h"
#import "DUOperationLogView.h"
#import "DURestoreViewController.h"
#import "AppearanceMetrics.h"
#import "DUStorageManager.h"

static NSString * const kTabIdentifierFirstAid = @"firstaid";
static NSString * const kTabIdentifierErase = @"erase";
static NSString * const kTabIdentifierPartition = @"partition";
static NSString * const kTabIdentifierRAID = @"raid";
static NSString * const kTabIdentifierRestore = @"restore";

@interface DUOperationController ()
@property (nonatomic, strong, readwrite) NSTabView *tabView;
@property (nonatomic, strong, readwrite) DUOperationLogView *logView;
@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong) NSView *partitionPane;
@property (nonatomic, strong) NSView *raidPane;
@property (nonatomic, strong) DUFirstAidViewController *firstAidPane_;
@property (nonatomic, strong) DUEraseViewController *erasePane_;
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

    _firstAidPane_ =
        [[DUFirstAidViewController alloc]
            initWithStorageManager:manager logView:_logView];
    _erasePane_ =
        [[DUEraseViewController alloc]
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
                          view:self.partitionPaneView];
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
    set(kTabIdentifierPartition, capabilities.canPartition,
        self.partitionPaneView);
    set(kTabIdentifierRAID, capabilities.canCreateRAID,
        self.raidPaneView);
    set(kTabIdentifierRestore, capabilities.canRestore,
        _restorePane_.view);

    [_firstAidPane_ refreshForObject:object capabilities:capabilities];
    [_erasePane_ refreshForObject:object capabilities:capabilities];
    [_restorePane_ refreshForObject:object capabilities:capabilities];
}

- (void)setControlsEnabled:(BOOL)enabled
{
    [_firstAidPane_ setControlsEnabled:enabled];
    [_erasePane_ setControlsEnabled:enabled];
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
- (NSView *)partitionPaneView
{
    return _partitionPane ?: _unavailablePlaceholder;
}

- (NSView *)raidPaneView
{
    return _raidPane ?: _unavailablePlaceholder;
}

- (void)setPartitionPane:(NSView *)view
{
    if (view == nil) {
        return;
    }
    _partitionPane = view;
}

- (void)setRAIDPane:(NSView *)view
{
    if (view == nil) {
        return;
    }
    _raidPane = view;
}

@end
