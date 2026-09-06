/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPartitionViewController.h"

#import <objc/runtime.h>

#import "AppearanceMetrics.h"
#import "DUDiskMapView.h"
#import "DUErrors.h"
#import "DUOperationLogView.h"
#import "DUPaneView.h"
#import "DUParsing.h"
#import "DUPartition.h"
#import "DUPartitionLayout.h"
#import "DUPartitionPlan.h"
#import "DUPartitionTableParser.h"
#import "DUStorageBackend.h"
#import "DUStorageCapabilities.h"
#import "DUStorageDevice.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"

// Floor for newly created partitions; mirrors the minimum enforced by
// DUPartitionLayout (ARCHITECTURE.md section 44).
static const unsigned long long kMinimumNewPartitionBytes =
    1024ull * 1024ull;

// Width of the volume information column; a column split with no
// counterpart in AppearanceMetrics.h.
static const CGFloat kVolumeFormWidth = 150.0;

static NSString *const kDefaultsConfirmDestructive =
    @"DUConfirmDestructiveOperations";

@interface DUPartitionViewController ()
    <DUDiskMapViewDelegate, NSTextFieldDelegate>

@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong) DUOperationLogView *logView;
@property (nonatomic, strong, readwrite) NSView *view;

@property (nonatomic, strong) NSTextField *schemeTitle;
@property (nonatomic, strong) NSPopUpButton *schemePopup;
@property (nonatomic, strong) DUDiskMapView *mapView;
@property (nonatomic, strong) NSTextField *nameTitle;
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSTextField *formatTitle;
@property (nonatomic, strong) NSPopUpButton *formatPopup;
@property (nonatomic, strong) NSTextField *sizeTitle;
@property (nonatomic, strong) NSTextField *sizeValue;
@property (nonatomic, strong) NSButton *addButton;
@property (nonatomic, strong) NSButton *removeButton;
@property (nonatomic, strong) NSButton *optionsButton;
@property (nonatomic, strong) NSButton *revertButton;
@property (nonatomic, strong) NSButton *applyButton;

@property (nonatomic, weak) DUStorageDevice *device;
@property (nonatomic, strong) DUPartitionLayout *layout;

// Baseline snapshot taken at refresh time. The layout cannot restore its
// own scheme (immutable property), so full revert rebuilds from here.
@property (nonatomic, copy) NSArray<DUPartition *> *committedPartitions;
@property (nonatomic, copy) NSString *committedScheme;

@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) BOOL operationRunning;
@property (nonatomic, assign) BOOL externallyDisabled;
@property (nonatomic, strong) DUStorageCapabilities *currentCapabilities;

// Radios of the open Options dialog; kept so the Done handler can read
// the choice after the modal loop ends.
@property (nonatomic, strong) NSArray<NSButton *> *pendingSchemeRadios;
@end

@implementation DUPartitionViewController

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
                                logView:(DUOperationLogView *)logView
{
    NSParameterAssert(manager != nil);
    NSParameterAssert(logView != nil);
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _storageManager = manager;
    _logView = logView;
    _selectedIndex = -1;

    // DUPaneView re-runs the layout whenever the tab view resizes us.
    CGFloat width = 400.0;
    CGFloat height = 300.0;
    DUPaneView *pane = [[DUPaneView alloc]
        initWithFrame:NSMakeRect(0, 0, width, height)];
    pane.layoutOwner = self;
    pane.layoutSelector = @selector(relayout);
    _view = pane;
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Top row: volume scheme selector (partition count options, SPEC
    // sections 15/18).
    _schemeTitle = [self label:NSLocalizedString(@"Volume Scheme:", nil)];
    _schemePopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(0, 0, 160, METRICS_BUTTON_HEIGHT)];
    [_schemePopup setTarget:self];
    [_schemePopup setAction:@selector(schemeCountChanged:)];

    // Partition map on the left, expanding (SPEC section 16).
    _mapView = [[DUDiskMapView alloc]
        initWithFrame:NSMakeRect(0, 0, 100, 100)];
    _mapView.delegate = self;

    // Volume information column on the right (SPEC section 17).
    _nameTitle = [self label:NSLocalizedString(@"Name:", nil)];
    _nameField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(0, 0, 80, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    _nameField.delegate = self;

    _formatTitle = [self label:NSLocalizedString(@"Format:", nil)];
    _formatPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(0, 0, 80, METRICS_BUTTON_HEIGHT)];
    [_formatPopup setTarget:self];
    [_formatPopup setAction:@selector(formatChanged:)];

    _sizeTitle = [self label:NSLocalizedString(@"Size:", nil)];
    _sizeValue = [[NSTextField alloc]
        initWithFrame:NSMakeRect(0, 0, 80, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    _sizeValue.editable = NO;
    _sizeValue.bezeled = NO;
    _sizeValue.drawsBackground = NO;

    // Partition controls below the map (SPEC section 18).
    _addButton = [self smallButtonWithTitle:@"+"
                                     action:@selector(addClicked:)];
    _removeButton = [self smallButtonWithTitle:@"-"
                                        action:@selector(removeClicked:)];
    _optionsButton =
        [self buttonWithTitle:NSLocalizedString(@"Options...", nil)
                       action:@selector(optionsClicked:)];
    _revertButton = [self buttonWithTitle:NSLocalizedString(@"Revert", nil)
                                   action:@selector(revertClicked:)];
    _applyButton = [self buttonWithTitle:NSLocalizedString(@"Apply", nil)
                                  action:@selector(applyClicked:)];

    NSArray<NSView *> *subviews = @[
        _schemeTitle, _schemePopup, _mapView,
        _nameTitle, _nameField, _formatTitle, _formatPopup,
        _sizeTitle, _sizeValue,
        _addButton, _removeButton, _optionsButton,
        _revertButton, _applyButton
    ];
    for (NSView *subview in subviews) {
        [_view addSubview:subview];
    }

    [self applyFramesForWidth:NSWidth(_view.frame)
                       height:NSHeight(_view.frame)];
    return self;
}

#pragma mark - Control factories

- (NSTextField *)label:(NSString *)text
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.editable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.stringValue = text;
    label.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [label sizeToFit];
    return label;
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action
{
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.title = title;
    button.bezelStyle = NSRoundedBezelStyle;
    button.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [button sizeToFit];
    {
        NSRect frame = button.frame;
        frame.size.height = METRICS_BUTTON_SMALL_HEIGHT;
        button.frame = frame;
    }
    [button setTarget:self];
    [button setAction:action];
    return button;
}

- (NSButton *)smallButtonWithTitle:(NSString *)title action:(SEL)action
{
    NSButton *button = [self buttonWithTitle:title action:action];
    button.font = METRICS_FONT_SYSTEM_BOLD_11;
    [button sizeToFit];
    /* Re-clamp: sizeToFit after the bold-font swap can re-expand the frame
     * past the small-button height (HIG small buttons are 17px). */
    NSRect frame = button.frame;
    frame.size.height = METRICS_BUTTON_SMALL_HEIGHT;
    button.frame = frame;
    return button;
}

#pragma mark - Frames and resize behavior

// Manual layout once at build time; live resizing is handled through
// autoresizing masks assigned below (SPEC section 36).
- (void)applyFramesForWidth:(CGFloat)width height:(CGFloat)height
{
    CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat bottom = METRICS_CONTENT_BOTTOM_MARGIN;

    // Bottom row: Revert left, Apply right.
    CGFloat bottomRowY = bottom;
    _revertButton.frameOrigin = NSMakePoint(side, bottomRowY);
    _applyButton.frameOrigin =
        NSMakePoint(width - side - NSWidth(_applyButton.frame), bottomRowY);

    // Controls row above: +/- on the left, Options... on the right.
    CGFloat controlsRowY =
        bottomRowY + METRICS_BUTTON_SMALL_HEIGHT + METRICS_SPACE_16;
    _addButton.frameOrigin = NSMakePoint(side, controlsRowY);
    _removeButton.frameOrigin =
        NSMakePoint(NSMaxX(_addButton.frame) + METRICS_BUTTON_HORIZ_INTERSPACE,
                    controlsRowY);
    _optionsButton.frameOrigin =
        NSMakePoint(width - side - NSWidth(_optionsButton.frame),
                    controlsRowY);

    // Top row: scheme label plus popup filling the rest of the line.
    CGFloat topRowY =
        height - METRICS_CONTENT_TOP_MARGIN - METRICS_BUTTON_HEIGHT;
    _schemePopup.frame =
        NSMakeRect(width - side - NSWidth(_schemePopup.frame),
                   topRowY, NSWidth(_schemePopup.frame),
                   METRICS_BUTTON_HEIGHT);
    _schemeTitle.frameOrigin =
        NSMakePoint(side, topRowY + (METRICS_BUTTON_HEIGHT -
                                     NSHeight(_schemeTitle.frame)) / 2.0);

    // Middle band: map on the left, volume info column pinned right.
    CGFloat controlsHeight = METRICS_BUTTON_SMALL_HEIGHT;
    CGFloat bandBottom = controlsRowY + controlsHeight + METRICS_SPACE_8;
    CGFloat bandTop = topRowY - METRICS_SPACE_8;
    CGFloat formLeft = width - side - kVolumeFormWidth;

    // The map fills the whole band between the scheme row and the
    // +/- controls row; the info column keeps a 16px gutter to its right.
    CGFloat mapWidth = formLeft - METRICS_SPACE_16 - side;
    if (mapWidth < 80.0) {
        mapWidth = 80.0;
    }
    CGFloat bandHeight = bandTop - bandBottom;
    if (bandHeight < 40.0) {
        bandHeight = 40.0;
    }
    _mapView.frame = NSMakeRect(side, bandBottom, mapWidth, bandHeight);

    /* The three form rows stack BOTTOM-UP, vertically centered against the
     * map. In tight panes the 12px row gaps compress (2px floor) so the
     * top row can never ride up into the scheme popup - the rows themselves
     * always fit because the form column is beside the map, not inside the
     * band's height budget. */
    CGFloat formGap = METRICS_SPACE_12;
    CGFloat fixedFormRows = METRICS_TEXT_INPUT_FIELD_HEIGHT +
        METRICS_BUTTON_HEIGHT + METRICS_TEXT_INPUT_FIELD_HEIGHT;
    CGFloat formSpace = bandHeight - METRICS_SPACE_8;
    if (fixedFormRows + 2 * formGap > formSpace) {
        formGap = MAX(2.0, (formSpace - fixedFormRows) / 2.0);
    }
    CGFloat formBlockHeight = fixedFormRows + 2 * formGap;
    CGFloat formBottom = bandBottom +
        MAX((bandHeight - formBlockHeight) / 2.0, 0.0);
    CGFloat formRowY[3];
    formRowY[0] = formBottom;                                         // name
    formRowY[1] = formRowY[0] + METRICS_TEXT_INPUT_FIELD_HEIGHT + formGap; // format
    formRowY[2] = formRowY[1] + METRICS_BUTTON_HEIGHT + formGap;      // size


    CGFloat labelColumnWidth = MAX(MAX(NSWidth(_nameTitle.frame),
                                       NSWidth(_formatTitle.frame)),
                                   NSWidth(_sizeTitle.frame));
    CGFloat fieldValueWidth =
        kVolumeFormWidth - labelColumnWidth - METRICS_SPACE_8;
    if (fieldValueWidth < 40.0) {
        fieldValueWidth = 40.0;
    }
    CGFloat fieldX = formLeft + labelColumnWidth + METRICS_SPACE_8;

    _nameField.frame = NSMakeRect(fieldX, formRowY[0],
                                  fieldValueWidth,
                                  METRICS_TEXT_INPUT_FIELD_HEIGHT);
    [_nameTitle setFrameOrigin:
        NSMakePoint(formLeft, formRowY[0] +
            (METRICS_TEXT_INPUT_FIELD_HEIGHT -
             NSHeight(_nameTitle.frame)) / 2.0)];

    _formatPopup.frame =
        NSMakeRect(fieldX, formRowY[1],
                   fieldValueWidth, METRICS_BUTTON_HEIGHT);
    [_formatTitle setFrameOrigin:
        NSMakePoint(formLeft, formRowY[1] +
            (METRICS_TEXT_INPUT_FIELD_HEIGHT -
             NSHeight(_formatTitle.frame)) / 2.0)];

    _sizeValue.frame =
        NSMakeRect(fieldX, formRowY[2],
                   fieldValueWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    [_sizeTitle setFrameOrigin:
        NSMakePoint(formLeft, formRowY[2] +
            (METRICS_TEXT_INPUT_FIELD_HEIGHT -
             NSHeight(_sizeTitle.frame)) / 2.0)];

    // Resize behavior: the map absorbs growth; rows pin to their window
    // edge (top row up, bottom rows down, form column rides with the top).
    _mapView.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    _schemeTitle.autoresizingMask = NSViewMinYMargin;
    _schemePopup.autoresizingMask =
        NSViewMinYMargin | NSViewMinXMargin;
    for (NSView *formWidget in @[ _nameTitle, _nameField,
                                  _formatTitle, _formatPopup,
                                  _sizeTitle, _sizeValue ]) {
        formWidget.autoresizingMask = NSViewMinYMargin;
    }
    for (NSView *leftButton in @[ _addButton, _removeButton,
                                  _revertButton ]) {
        leftButton.autoresizingMask = NSViewMaxYMargin;
    }
    for (NSView *rightControl in @[ _optionsButton, _applyButton ]) {
        rightControl.autoresizingMask =
            NSViewMaxYMargin | NSViewMinXMargin;
    }
}

#pragma mark - Selection state

- (void)refreshForObject:(DUStorageObject *)object
             capabilities:(DUStorageCapabilities *)capabilities
{
    // Never clobber an in-flight apply; the completion path resyncs.
    if (_operationRunning) {
        return;
    }
    _currentCapabilities = capabilities;

    // Same disk still selected and edits pending: keep the working plan
    // (fan-outs from unrelated rescans must not wipe it) and just adopt
    // the fresh model object so a later apply targets the live catalog.
    DUStorageDevice *device = (object != nil &&
        object.type == DUStorageObjectTypeDevice)
        ? (DUStorageDevice *)object : nil;
    if (_layout != nil && _layout.hasPendingChanges && device != nil &&
            _device != nil &&
            [device.identifier isEqualToString:_device.identifier]) {
        _device = device;
        return;
    }

    if (device != nil && device.capacityBytes > 0) {
        _device = device;
        _committedPartitions = [self partitionChildrenOfDevice:_device];
        _committedScheme =
            [DUPartitionTableParser normalizeSchemeToken:
                 _device.partitionScheme];

        NSError *error = nil;
        DUPartitionLayout *built =
            [self buildLayoutWithCapacity:_device.capacityBytes
                                   scheme:_committedScheme
                               partitions:_committedPartitions
                                    error:&error];
        if (built == nil) {
            [self showError:NSLocalizedString(
                                @"Could not read the partition table.", nil)
                    detail:error.localizedDescription];
            _device = nil;
            _layout = nil;
            _committedPartitions = @[];
        } else {
            _layout = built;
            [_layout commitAsBaseline];
        }
    } else {
        _device = nil;
        _layout = nil;
        _committedPartitions = @[];
    }

    _selectedIndex = -1;
    [self syncAllViews];
}

// Deep-copies the device's partition children; volumes hang off partitions
// and are deliberately not carried into the editor.
- (NSArray<DUPartition *> *)partitionChildrenOfDevice:
    (DUStorageDevice *)device
{
    NSMutableArray<DUPartition *> *children =
        [NSMutableArray arrayWithCapacity:device.children.count];
    for (DUStorageObject *child in device.children) {
        if (child.type != DUStorageObjectTypePartition) {
            continue;
        }
        [children addObject:[(DUPartition *)child copy]];
    }
    return children;
}

// Builds a layout by replaying addPartition calls in offset order. The
// layout API has no insert-at-offset, so original gaps collapse; sizes,
// names and formats are preserved.
- (DUPartitionLayout *)buildLayoutWithCapacity:(unsigned long long)capacity
                                        scheme:(NSString *)scheme
                                    partitions:(NSArray<DUPartition *> *)source
                                         error:(NSError **)error
{
    DUPartitionLayout *fresh =
        [[DUPartitionLayout alloc] initWithCapacity:capacity scheme:scheme];
    NSArray<DUPartition *> *ordered =
        [source sortedArrayUsingComparator:
            ^NSComparisonResult(DUPartition *a, DUPartition *b) {
                if (a.offsetBytes < b.offsetBytes) {
                    return NSOrderedAscending;
                }
                if (a.offsetBytes > b.offsetBytes) {
                    return NSOrderedDescending;
                }
                return NSOrderedSame;
            }];
    for (DUPartition *source_partition in ordered) {
        NSSet<NSString *> *knownIdentifiers = [NSSet setWithArray:
            [fresh.partitions valueForKey:@"identifier"]];
        if (![fresh addPartitionWithSize:source_partition.sizeBytes
                                    name:source_partition.name
                                   error:error]) {
            return nil;
        }
        DUPartition *added =
            [self addedPartitionInLayout:fresh excluding:knownIdentifiers];
        if (added != nil) {
            [fresh setFormat:source_partition.filesystemType
                forPartition:added];
        }
    }
    return fresh;
}

// The layout assigns its own identifiers, so the freshly inserted entry is
// found by identifier diff instead of position.
- (DUPartition *)addedPartitionInLayout:(DUPartitionLayout *)layout
                              excluding:(NSSet<NSString *> *)identifiers
{
    for (DUPartition *candidate in layout.partitions) {
        if (![identifiers containsObject:candidate.identifier]) {
            return candidate;
        }
    }
    return nil;
}

#pragma mark - View synchronization

- (DUPartition *)selectedPartition
{
    if (_layout == nil || _selectedIndex < 0 ||
        _selectedIndex >= (NSInteger)_layout.partitions.count) {
        return nil;
    }
    return _layout.partitions[(NSUInteger)_selectedIndex];
}

- (void)syncAllViews
{
    BOOL hasDevice = _device != nil && _layout != nil;

    if (hasDevice) {
        /* The map auto-selects the first tile in setLayout: but does not
         * notify the delegate, so mirror that choice here to keep the info
         * form live right after a refresh. */
        if (_selectedIndex < 0 ||
            _selectedIndex >= (NSInteger)_layout.partitions.count) {
            _selectedIndex =
                _layout.partitions.count > 0 ? 0 : -1;
        }
    } else {
        _selectedIndex = -1;
    }

    [_mapView setLayout:hasDevice ? _layout : nil];
    [_mapView setSelectedPartitionIndex:_selectedIndex];

    [self rebuildSchemePopup];
    [self syncInfoForm];
    [self updateEnabledStates];
}

- (void)syncInfoForm
{
    DUPartition *selected = [self selectedPartition];
    if (selected == nil) {
        _nameField.stringValue = @"";
        [_formatPopup removeAllItems];
        _sizeValue.stringValue = @"";
        return;
    }

    // Keep the field out of the notification loop while reflecting model
    // state back into it.
    _nameField.stringValue = selected.name.length > 0
        ? selected.name
        : (selected.displayName ?: @"");

    [self rebuildFormatPopupForFilesystem:selected.filesystemType];

    unsigned long long shownSize = selected.sizeBytes;
    if (_mapView.layout != nil && _mapView.selectedPartitionIndex ==
            _selectedIndex) {
        // During boundary drags the map holds the previewed size; mirror it
        // so the Size line tracks the pointer.
        NSArray<DUPartition *> *mapped = _mapView.layout.partitions;
        if (_selectedIndex < (NSInteger)mapped.count) {
            shownSize =
                mapped[(NSUInteger)_selectedIndex].sizeBytes;
        }
    }
    _sizeValue.stringValue =
        [DUParsing humanReadableSizeFromBytes:shownSize];
}

// Format choices come from the backend for the whole device; the matching
// entry is preselected for the chosen filesystem (SPEC section 17).
- (void)rebuildFormatPopupForFilesystem:(NSString *)filesystemType
{
    [_formatPopup removeAllItems];
    if (_device == nil) {
        return;
    }
    NSArray<NSDictionary *> *formats =
        [self.storageManager supportedFormatsForObject:_device];
    NSInteger matchIndex = -1;
    NSUInteger index = 0;
    for (NSDictionary *format in formats) {
        if (![format[kDUFormatCanFormatKey] boolValue]) {
            continue;
        }
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:format[kDUFormatDisplayNameKey] ?: @""
                   action:nil
            keyEquivalent:@""];
        item.representedObject = format[kDUFormatIdentifierKey];
        [_formatPopup.menu addItem:item];
        if (filesystemType.length > 0 &&
            [format[kDUFormatIdentifierKey]
                isEqualToString:filesystemType]) {
            matchIndex = (NSInteger)_formatPopup.itemArray.count - 1;
        }
        index++;
    }
    (void)index;
    if (_formatPopup.itemArray.count > 0) {
        [_formatPopup selectItemAtIndex:
            matchIndex >= 0 ? matchIndex : 0];
    }
}

// Count options are rebuilt dynamically under the active scheme limit;
// feasibility is probed on a scratch copy so menu entries never offer a
// count the layout could not materialize (SPEC sections 15/18). The
// offered range is capped to keep the popup menu usable; higher counts
// remain reachable through repeated "+".
- (void)rebuildSchemePopup
{
    [_schemePopup removeAllItems];
    if (_layout == nil) {
        return;
    }
    const NSUInteger kMaximumOfferedCount = 16;
    NSUInteger currentCount = _layout.partitions.count;
    NSUInteger feasibleCount = [self maximumFeasiblePartitionCount];
    NSUInteger capped =
        MIN(feasibleCount, kMaximumOfferedCount);
    NSUInteger itemCount = MAX(currentCount, capped);
    for (NSUInteger n = 1; n <= itemCount; n++) {
        NSString *title =
            n == 1
                ? NSLocalizedString(@"1 Partition", nil)
                : [NSString stringWithFormat:
                       NSLocalizedString(@"%lu Partitions", nil),
                       (unsigned long)n];
        [_schemePopup addItemWithTitle:title];
        _schemePopup.lastItem.representedObject = @(n);
    }
    if (currentCount >= 1 && currentCount <= itemCount) {
        [_schemePopup selectItemAtIndex:(NSInteger)currentCount - 1];
    }
}

- (NSUInteger)maximumFeasiblePartitionCount
{
    if (_layout == nil) {
        return 0;
    }
    NSError *error = nil;
    DUPartitionLayout *scratch =
        [self buildLayoutWithCapacity:_layout.capacityBytes
                               scheme:_layout.scheme
                           partitions:_layout.partitions
                                error:&error];
    if (scratch == nil) {
        return _layout.partitions.count;
    }
    NSUInteger count = scratch.partitions.count;
    // Defensive cap; the layout itself enforces scheme limits.
    while (count < 256 &&
           [scratch addPartitionWithSize:kMinimumNewPartitionBytes
                                    name:nil
                                   error:nil]) {
        count++;
    }
    return count;
}

- (void)updateEnabledStates
{
    BOOL busy = _operationRunning || _externallyDisabled;
    BOOL hasDevice = _device != nil && _layout != nil;
    BOOL writable = hasDevice && !_device.readOnly;
    BOOL pending = hasDevice && _layout.hasPendingChanges;
    // validate: is cheap and pure; passing NULL skips error creation.
    BOOL valid = pending ? [_layout validate:NULL] : YES;

    _applyButton.enabled = pending && valid && !busy;
    _revertButton.enabled = pending && !busy;
    _optionsButton.enabled = writable && !busy;
    _addButton.enabled = writable && !busy;
    _removeButton.enabled =
        writable && !busy && [self selectedPartition] != nil;
    _nameField.enabled = [self selectedPartition] != nil && !busy;
    _formatPopup.enabled = _nameField.isEnabled && !busy;
    _mapView.resizingEnabled =
        writable && !busy &&
        (_currentCapabilities.canResize || _currentCapabilities.canPartition);
}

- (void)setControlsEnabled:(BOOL)enabled
{
    _externallyDisabled = !enabled;
    [self updateEnabledStates];
}

#pragma mark - DUDiskMapViewDelegate

- (void)mapView:(DUDiskMapView *)sender
    didSelectPartitionAtIndex:(NSUInteger)index
{
    (void)sender;
    _selectedIndex = (NSInteger)index;
    [self syncInfoForm];
    [self updateEnabledStates];
}

- (void)mapViewDidChangeLayout:(DUDiskMapView *)sender
{
    (void)sender;
    [self syncInfoForm];
    [self updateEnabledStates];
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification *)notification
{
    if (notification.object != _nameField) {
        return;
    }
    DUPartition *selected = [self selectedPartition];
    if (selected == nil) {
        return;
    }
    NSString *trimmed = [DUParsing trimmedString:_nameField.stringValue];
    [_layout renamePartition:selected toName:trimmed.length > 0
                                 ? trimmed : nil];
    [_mapView setNeedsDisplay:YES];
    [self updateEnabledStates];
}

#pragma mark - Actions

// Format choice on the selected partition; recorded as a pending change
// like renames and resizes (SPEC section 17).
- (void)formatChanged:(id)sender
{
    (void)sender;
    DUPartition *selected = [self selectedPartition];
    NSString *identifier = _formatPopup.selectedItem.representedObject;
    if (selected == nil || identifier.length == 0 || _layout == nil) {
        return;
    }
    [_layout setFormat:identifier forPartition:selected];
    [self updateEnabledStates];
}

// The popup selects a target partition count; shrinking removes from the
// end, growing splits the largest remaining gap (classic Disk Utility
// behavior adapted to the map-based editor).
- (void)schemeCountChanged:(id)sender
{
    (void)sender;
    NSNumber *targetNumber = _schemePopup.selectedItem.representedObject;
    if (targetNumber == nil || _layout == nil || _device == nil ||
        _operationRunning) {
        return;
    }
    NSUInteger target = (NSUInteger)targetNumber.integerValue;

    while (_layout.partitions.count > target) {
        DUPartition *last = _layout.partitions.lastObject;
        NSError *error = nil;
        if (![_layout removePartition:last error:&error]) {
            [self showError:NSLocalizedString(
                                @"Could not remove the partition.", nil)
                    detail:error.localizedDescription];
            break;
        }
        _selectedIndex = -1;
    }

    while (_layout.partitions.count < target) {
        unsigned long long gapBytes = [self largestFreeGapBytes];
        unsigned long long wanted = MAX(gapBytes / 2,
                                        kMinimumNewPartitionBytes);
        if (wanted > gapBytes) {
            [self showError:NSLocalizedString(
                                @"Not enough free space for another "
                                @"partition.", nil)
                    detail:nil];
            break;
        }
        NSSet<NSString *> *knownIdentifiers = [NSSet setWithArray:
            [_layout.partitions valueForKey:@"identifier"]];
        NSError *error = nil;
        if (![_layout addPartitionWithSize:wanted
                                      name:[self nextDefaultPartitionName]
                                     error:&error]) {
            [self showError:NSLocalizedString(
                                @"Could not add a partition.", nil)
                    detail:error.localizedDescription];
            break;
        }
        [self applyDefaultFormatToAddedPartitionExcluding:
            knownIdentifiers];
    }

    [self syncAllViews];
}

- (unsigned long long)largestFreeGapBytes
{
    if (_layout.capacityBytes == 0) {
        return 0;
    }
    NSArray<DUPartition *> *sorted = _layout.partitions;
    if (sorted.count == 0) {
        return _layout.capacityBytes;
    }
    unsigned long long largest = 0;
    unsigned long long previousEnd = 0;
    for (DUPartition *partition in sorted) {
        if (partition.offsetBytes > previousEnd) {
            largest = MAX(largest,
                          partition.offsetBytes - previousEnd);
        }
        previousEnd = partition.offsetBytes + partition.sizeBytes;
    }
    if (previousEnd < _layout.capacityBytes) {
        largest = MAX(largest, _layout.capacityBytes - previousEnd);
    }
    return largest;
}

// The just-added partition gets the format currently chosen in the
// popup; it is identified by identifier diff because the layout assigns
// its own identifiers and keeps partitions sorted by offset.
- (void)applyDefaultFormatToAddedPartitionExcluding:
    (NSSet<NSString *> *)knownIdentifiers
{
    NSString *defaultIdentifier = _formatPopup.selectedItem.representedObject;
    if (defaultIdentifier.length == 0) {
        return;
    }
    DUPartition *added =
        [self addedPartitionInLayout:_layout excluding:knownIdentifiers];
    if (added != nil) {
        [_layout setFormat:defaultIdentifier forPartition:added];
    }
}

// Default name for a new partition: "Partition n" numbered by position
// (count + 1), bumped past any name already in use so repeated
// add/remove cycles never produce duplicates. The Name field stays
// editable for a real label.
- (NSString *)nextDefaultPartitionName
{
    NSUInteger number = _layout.partitions.count + 1;
    for (;;) {
        NSString *candidate = [NSString stringWithFormat:
            NSLocalizedString(@"Partition %lu", nil),
            (unsigned long)number];
        BOOL taken = NO;
        for (DUPartition *partition in _layout.partitions) {
            if ([partition.name isEqualToString:candidate]) {
                taken = YES;
                break;
            }
        }
        if (!taken) {
            return candidate;
        }
        number++;
    }
}

- (void)addClicked:(id)sender
{
    (void)sender;
    if (_layout == nil || _device == nil || _operationRunning) {
        return;
    }
    // "+" fills the trailing free space after the last partition (or the
    // whole disk when empty).
    unsigned long long gapBytes =
        _layout.partitions.count > 0
            ? [_layout freeBytesAfterPartition:
                  _layout.partitions.lastObject]
            : _layout.capacityBytes;
    if (gapBytes < kMinimumNewPartitionBytes) {
        [self showError:NSLocalizedString(
                            @"No free space behind the last partition.",
                            nil)
                detail:nil];
        return;
    }
    NSSet<NSString *> *knownIdentifiers = [NSSet setWithArray:
        [_layout.partitions valueForKey:@"identifier"]];
    NSError *error = nil;
    if (![_layout addPartitionWithSize:gapBytes
                                  name:[self nextDefaultPartitionName]
                                 error:&error]) {
        [self showError:NSLocalizedString(@"Could not add a partition.",
                                          nil)
                detail:error.localizedDescription];
        return;
    }
    [self applyDefaultFormatToAddedPartitionExcluding:knownIdentifiers];
    _selectedIndex = (NSInteger)_layout.partitions.count - 1;
    [self syncAllViews];
}

- (void)removeClicked:(id)sender
{
    (void)sender;
    DUPartition *selected = [self selectedPartition];
    if (selected == nil || _operationRunning) {
        return;
    }
    NSError *error = nil;
    if (![_layout removePartition:selected error:&error]) {
        [self showError:NSLocalizedString(@"Could not remove the "
                                          @"partition.", nil)
                detail:error.localizedDescription];
        return;
    }
    _selectedIndex = -1;
    [self syncAllViews];
}

// Modal radio panel for the partition-table scheme (SPEC section 18).
- (void)optionsClicked:(id)sender
{
    (void)sender;
    if (_device == nil || _layout == nil || _operationRunning) {
        return;
    }
    NSArray<NSString *> *schemes = @[ @"gpt", @"mbr", @"bsd" ];

    CGFloat panelWidth = 320.0;
    CGFloat listHeight =
        (CGFloat)schemes.count * METRICS_RADIO_BUTTON_LINE_SPACING;
    CGFloat panelHeight = METRICS_CONTENT_TOP_MARGIN + listHeight +
        METRICS_BUTTON_VERT_INTERSPACE + METRICS_BUTTON_HEIGHT +
        METRICS_CONTENT_BOTTOM_MARGIN;
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, panelWidth, panelHeight)
                  styleMask:NSTitledWindowMask
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = NSLocalizedString(@"Partition Table Scheme", nil);
    NSView *content = panel.contentView;

    NSMutableArray<NSButton *> *radios =
        [NSMutableArray arrayWithCapacity:schemes.count];
    CGFloat radioY = NSHeight(content.frame) -
        METRICS_CONTENT_TOP_MARGIN - METRICS_RADIO_BUTTON_SIZE;
    for (NSString *scheme in schemes) {
        NSButton *radio = [[NSButton alloc]
            initWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, radioY,
                                     panelWidth -
                                         2 * METRICS_CONTENT_SIDE_MARGIN,
                                     METRICS_RADIO_BUTTON_SIZE)];
        radio.buttonType = NSRadioButton;
        radio.font = METRICS_FONT_SYSTEM_REGULAR_11;
        radio.title = [DUPartitionTableParser displayNameForScheme:scheme];
        // NSButton carries no representedObject; the scheme rides along
        // via an associated object (same pattern as the erase dialog).
        objc_setAssociatedObject(radio, "duScheme", scheme,
                                 OBJC_ASSOCIATION_COPY);
        if ((_layout.scheme.length == 0 &&
             [scheme isEqualToString:@"gpt"]) ||
            [scheme isEqualToString:_layout.scheme]) {
            radio.state = NSOnState;
        }
        [content addSubview:radio];
        [radios addObject:radio];
        radioY -= METRICS_RADIO_BUTTON_LINE_SPACING;
    }

    NSButton *doneButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(NSWidth(content.frame) -
                                     METRICS_CONTENT_SIDE_MARGIN -
                                     METRICS_BUTTON_MIN_WIDTH,
                                 METRICS_CONTENT_BOTTOM_MARGIN,
                                 METRICS_BUTTON_MIN_WIDTH,
                                 METRICS_BUTTON_HEIGHT)];
    doneButton.title = NSLocalizedString(@"OK", nil);
    doneButton.bezelStyle = NSRoundedBezelStyle;
    [doneButton sizeToFit];
    doneButton.keyEquivalent = @"\r";
    [doneButton setTarget:self];
    [doneButton setAction:@selector(schemeDialogDone:)];
    [content addSubview:doneButton];

    NSButton *cancelButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(NSMinX(doneButton.frame) -
                                     METRICS_BUTTON_HORIZ_INTERSPACE -
                                     METRICS_BUTTON_MIN_WIDTH,
                                 METRICS_CONTENT_BOTTOM_MARGIN,
                                 METRICS_BUTTON_MIN_WIDTH,
                                 METRICS_BUTTON_HEIGHT)];
    cancelButton.title = NSLocalizedString(@"Cancel", nil);
    cancelButton.bezelStyle = NSRoundedBezelStyle;
    [cancelButton sizeToFit];
    cancelButton.keyEquivalent = @"\033";
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(schemeDialogCancelled:)];
    [content addSubview:cancelButton];

    _pendingSchemeRadios = radios;
    NSApp = [NSApplication sharedApplication];
    [panel center];
    [NSApp runModalForWindow:panel];

    NSString *chosenScheme = nil;
    for (NSButton *radio in _pendingSchemeRadios) {
        if (radio.state == NSOnState) {
            chosenScheme =
                objc_getAssociatedObject(radio, "duScheme");
            break;
        }
    }
    [panel orderOut:nil];
    _pendingSchemeRadios = nil;

    if (chosenScheme.length == 0 ||
        [chosenScheme isEqualToString:_layout.scheme]) {
        return;
    }
    NSError *error = nil;
    if (![self applyScheme:chosenScheme error:&error]) {
        [self showError:NSLocalizedString(
                            @"The selected scheme does not fit the "
                            @"current layout.", nil)
                detail:error.localizedDescription];
        return;
    }
    [self syncAllViews];
}

- (void)schemeDialogDone:(id)sender
{
    (void)sender;
    [NSApp stopModal];
}

- (void)schemeDialogCancelled:(id)sender
{
    (void)sender;
    for (NSButton *radio in _pendingSchemeRadios) {
        radio.state = NSOffState;
    }
    [NSApp stopModal];
}

// Switching the scheme rebuilds the working layout under the new scheme;
// leaving the baseline uncommitted marks the pane dirty.
- (BOOL)applyScheme:(NSString *)scheme error:(NSError **)error
{
    NSError *buildError = nil;
    DUPartitionLayout *fresh =
        [self buildLayoutWithCapacity:_device.capacityBytes
                               scheme:scheme
                           partitions:_layout.partitions
                                error:&buildError];
    if (fresh == nil) {
        if (error != NULL) {
            *error = buildError;
        }
        return NO;
    }
    _layout = fresh;
    _selectedIndex = -1;
    return YES;
}

- (void)revertClicked:(id)sender
{
    (void)sender;
    if (_device == nil || _operationRunning) {
        return;
    }
    // Full revert including the scheme, which DUPartitionLayout itself
    // cannot restore because its scheme is immutable.
    NSError *error = nil;
    DUPartitionLayout *restored =
        [self buildLayoutWithCapacity:_device.capacityBytes
                               scheme:_committedScheme
                           partitions:_committedPartitions
                                error:&error];
    if (restored == nil) {
        [self showError:NSLocalizedString(
                            @"Could not restore the saved layout.", nil)
                detail:error.localizedDescription];
        return;
    }
    _layout = restored;
    [_layout commitAsBaseline];
    _selectedIndex = -1;
    [self syncAllViews];
}

- (void)applyClicked:(id)sender
{
    (void)sender;
    if (_device == nil || _layout == nil || _operationRunning) {
        return;
    }
    NSError *validationError = nil;
    if (![_layout validate:&validationError]) {
        [self showError:NSLocalizedString(
                            @"The proposed layout is not valid.", nil)
                detail:validationError.localizedDescription];
        return;
    }

    // Destructive confirmation listing what will be written (SPEC
    // sections 19/32); Cancel stays the default button.
    if ([[NSUserDefaults standardUserDefaults]
            boolForKey:kDefaultsConfirmDestructive]) {
        NSMutableString *summary =
            [NSMutableString stringWithCapacity:256];
        [summary appendString:NSLocalizedString(
            @"Applying will destroy all data on the disk and create these "
            @"partitions:\n\n", nil)];
        for (DUPartition *partition in _layout.partitions) {
            [summary appendFormat:@"%@ - %@\n",
                partition.name.length > 0
                    ? partition.name
                    : NSLocalizedString(@"Untitled", nil),
                [DUParsing humanReadableSizeFromBytes:
                     partition.sizeBytes]];
        }
        NSInteger choice = NSRunAlertPanel(
            NSLocalizedString(@"Apply partition changes", nil),
            @"%@",
            NSLocalizedString(@"Cancel", nil),
            NSLocalizedString(@"Apply", nil),
            nil,
            summary);
        if (choice != NSAlertAlternateReturn) {
            return;
        }
    }

    DUPartitionPlan *plan =
        [DUPartitionPlan planFromLayout:_layout
                              forDevice:_device
                             destructive:YES];
    if (plan == nil) {
        [self showError:NSLocalizedString(
                            @"Could not describe the partitioning "
                            @"operation.", nil)
                detail:nil];
        return;
    }

    NSError *lockError = nil;
    if (![self.storageManager acquireLock:_device.identifier
                                    error:&lockError]) {
        [self showError:NSLocalizedString(@"The device is busy.", nil)
                detail:lockError.localizedDescription];
        return;
    }

    [self.logView appendLine:[NSString stringWithFormat:
        NSLocalizedString(@"Applying partition changes to %@...", nil),
        _device.displayName ?: _device.identifier]];

    _operationRunning = YES;
    [self updateEnabledStates];

    __weak typeof(self) weakSelf = self;
    id<DUStorageBackend> backend = self.storageManager.backend;
    DUStorageObject *target = _device;
    NSString *lockIdentifier = _device.identifier;
    void (^progressBlock)(double, NSString *) =
        ^(double fraction, NSString *message) {
            (void)fraction;
            [weakSelf.logView appendLine:message ?: @""];
        };
    void (^completionBlock)(NSError *) =
        ^(NSError *completionError) {
            // Runs on an arbitrary thread: release the lock immediately,
            // everything else marshals to the main thread.
            [weakSelf.storageManager releaseLock:lockIdentifier];
            NSDictionary *result =
                @{ @"error" : completionError ?: [NSNull null] };
            [weakSelf performSelectorOnMainThread:
                @selector(applyFinishedWithResult:)
                                   withObject:result
                                waitUntilDone:NO];
        };

    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        [backend partitionDevice:target
                         withPlan:plan
                         progress:progressBlock
                       completion:completionBlock];
    }];
    worker.name = @"DU-Partition-Apply";
    [worker start];
}

// Main-thread continuation of the apply flow.
- (void)applyFinishedWithResult:(NSDictionary *)result
{
    _operationRunning = NO;
    NSError *error = result[@"error"] == [NSNull null]
        ? nil : result[@"error"];
    if (error == nil) {
        [_layout commitAsBaseline];
        _committedScheme = _layout.scheme;
        NSMutableArray<DUPartition *> *snapshot =
            [NSMutableArray arrayWithCapacity:_layout.partitions.count];
        for (DUPartition *partition in _layout.partitions) {
            [snapshot addObject:[partition copy]];
        }
        _committedPartitions = snapshot;
        [self.logView appendLine:NSLocalizedString(
            @"Partitioning completed successfully.", nil)];
    } else if (error.code == DUErrorCancelled) {
        [self.logView appendLine:NSLocalizedString(
            @"Partitioning cancelled.", nil)];
    } else {
        [self.logView appendLine:NSLocalizedString(
            @"Partitioning failed.", nil)];
        [self.logView appendLine:error.localizedDescription ?: @""];
    }
    [self updateEnabledStates];

    // Topology changed: rediscover on a background thread per the manager
    // contract so the browser picks up the new partition devices.
    DUStorageManager *manager = self.storageManager;
    NSThread *refresher = [[NSThread alloc] initWithBlock:^{
        NSError *refreshError = nil;
        [manager refreshWithError:&refreshError];
        (void)refreshError;
    }];
    refresher.name = @"DU-Partition-Refresh";
    [refresher start];
}

#pragma mark - Alerts

- (void)relayout
{
    [self applyFramesForWidth:NSWidth(self.view.frame)
                       height:NSHeight(self.view.frame)];
}

- (void)showError:(NSString *)message detail:(NSString *)detail
{
    NSString *text = detail.length > 0
        ? [NSString stringWithFormat:@"%@\n\n%@", message, detail]
        : message;
    NSRunAlertPanel(
        NSLocalizedString(@"Partition", nil),
        @"%@",
        NSLocalizedString(@"OK", nil),
        nil,
        nil,
        text);
}

@end
