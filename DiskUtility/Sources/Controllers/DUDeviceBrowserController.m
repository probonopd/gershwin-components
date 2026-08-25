/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUDeviceBrowserController.h"

#import "DUDeviceOutlineView.h"
#import "DUDiskImage.h"
#import "DUIcons.h"
#import "DUOpticalMedia.h"
#import "DUPartition.h"
#import "DURAIDSet.h"
#import "DUStorageDevice.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"
#import "DUStorageVolume.h"

static NSString * const kColumnIdentifier = @"devices";

@interface DUDeviceBrowserController ()
    <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong, readwrite) NSView *containerView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) DUDeviceOutlineView *outlineView;

// Flat mirror of the visible hierarchy; the outline queries this by row.
@property (nonatomic, copy) NSArray<DUStorageObject *> *visibleObjects;
// Row index -> depth so indentation survives without walking parents.
@property (nonatomic, copy) NSArray<NSNumber *> *rowDepths;
@end

@implementation DUDeviceBrowserController

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
{
    NSParameterAssert(manager != nil);
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _storageManager = manager;
    _visibleObjects = @[];
    _rowDepths = @[];

    _outlineView =
        [[DUDeviceOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 190, 300)];
    NSTableColumn *column =
        [[NSTableColumn alloc] initWithIdentifier:kColumnIdentifier];
    column.title = @"";
    column.resizingMask = NSTableColumnAutoresizingMask;
    column.width = 186.0;
    [_outlineView addTableColumn:column];
    _outlineView.outlineTableColumn = column;
    _outlineView.indentationPerLevel = 12.0;
    _outlineView.dataSource = self;
    _outlineView.delegate = self;
    _outlineView.autoresizesOutlineColumn = YES;
    [_outlineView setAction:@selector(outlineClicked:)];
    [_outlineView setTarget:self];
    // Accept file drops from the Workspace so image files can be added to the
    // list by dropping them onto the left pane.
    [_outlineView registerForDraggedTypes:@[ NSFilenamesPboardType,
                                             NSURLPboardType ]];

    _scrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, 0, 190, 300)];
    _scrollView.documentView = _outlineView;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.autoresizingMask = NSViewHeightSizable;

    _containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 190, 300)];
    // Fixed width pane per SPEC section 36; only height follows the window.
    _containerView.autoresizingMask = NSViewHeightSizable;
    _scrollView.frame = _containerView.bounds;
    [_containerView addSubview:_scrollView];
    return self;
}

#pragma mark - Reload

- (void)reloadWithPreferredSelection:(NSString *)preferredIdentifier
{
    // Preserve expansion + selection across topology refreshes.
    NSMutableSet<NSString *> *expanded = [NSMutableSet set];
    for (DUStorageObject *root in self.storageManager.currentObjects) {
        if ([self.outlineView isItemExpanded:root]) {
            [expanded addObject:root.identifier];
        }
    }
    NSString *selectedIdentifier = self.selectedObject.identifier;

    [self rebuildVisibleRows];

    [self.outlineView reloadData];
    for (DUStorageObject *root in self.storageManager.currentObjects) {
        if ([expanded containsObject:root.identifier]) {
            [self.outlineView expandItem:root];
        }
    }

    NSString *target = preferredIdentifier ?: selectedIdentifier;
    DUStorageObject *resolved = nil;
    if (target.length > 0) {
        resolved = [self storageObjectForVisibleIdentifier:target];
    }
    if (resolved == nil && self.visibleObjects.count > 0) {
        resolved = self.visibleObjects.firstObject;
    }
    if (resolved != nil) {
        NSUInteger row = [self.outlineView rowForItem:resolved];
        if (row != NSNotFound) {
            [self.outlineView selectRowIndexes:
                                  [NSIndexSet indexSetWithIndex:row]
                             byExtendingSelection:NO];
            return;
        }
    }
    [self notifySelection:nil];
}

- (void)rebuildVisibleRows
{
    NSMutableArray<DUStorageObject *> *rows = [NSMutableArray array];
    NSMutableArray<NSNumber *> *depths = [NSMutableArray array];
    // Iterative pre-order walk avoids the retain cycle a recursive block
    // would create under ARC.
    // Iterative pre-order walk avoids the retain cycle a recursive block
    // would create under ARC. Entries are (object, depth) pairs.
    NSMutableArray<NSArray<id> *> *work = [NSMutableArray array];
    for (DUStorageObject *root in [[self.storageManager.currentObjects reverseObjectEnumerator] allObjects]) {
        [work addObject:@[ root, @0 ]];
    }
    while (work.count > 0) {
        NSArray<id> *entry = work.lastObject;
        [work removeLastObject];
        DUStorageObject *object = entry[0];
        NSInteger depth = [entry[1] integerValue];
        // Show Only Volumes collapses the tree to leaf volumes; whole disks
        // and partitions are skipped so the outline reads as a flat volume
        // list (View > Show Only Volumes).
        if (self.showOnlyVolumes &&
            object.type != DUStorageObjectTypeVolume) {
            continue;
        }
        [rows addObject:object];
        [depths addObject:@(depth)];
        for (DUStorageObject *child in object.children) {
            [work addObject:@[ child, @(depth + 1) ]];
        }
    }
    self.visibleObjects = rows;
    self.rowDepths = depths;
}

- (DUStorageObject *)storageObjectForVisibleIdentifier:(NSString *)identifier
{
    for (DUStorageObject *candidate in self.visibleObjects) {
        if ([candidate.identifier isEqualToString:identifier]) {
            return candidate;
        }
    }
    return nil;
}

- (DUStorageObject *)selectedObject
{
    NSInteger row = self.outlineView.selectedRow;
    if (row < 0)
      {
        return nil;
      }
    /* -itemAtRow: is the authoritative mapping from visual row to model
     * object; indexing visibleObjects by row number can diverge when
     * items are collapsed or expanded. */
    id item = [self.outlineView itemAtRow: row];
    if (![item isKindOfClass:[DUStorageObject class]])
      {
        return nil;
      }
    return item;
}

#pragma mark - User intent

- (void)outlineClicked:(id)sender
{
    (void)sender;
    [self notifySelection:self.selectedObject];
}

// Column clicks carry no sorting behavior here.
- (void)outlineView:(NSOutlineView *)outlineView
    didClickTableColumn:(NSTableColumn *)aTableColumn
{
    (void)outlineView;
    (void)aTableColumn;
}

// Row-view hooks: default row views are used unchanged.
- (NSTableRowView *)outlineView:(NSOutlineView *)outlineView
                rowViewForItem:(id)item
{
    (void)outlineView;
    (void)item;
    return nil;
}

- (void)outlineView:(NSOutlineView *)outlineView
       didAddRowView:(NSTableRowView *)rowView
              forRow:(NSInteger)rowIndex
{
    (void)outlineView;
    (void)rowView;
    (void)rowIndex;
}

- (void)outlineView:(NSOutlineView *)outlineView
    didRemoveRowView:(NSTableRowView *)rowView
              forRow:(NSInteger)rowIndex
{
    (void)outlineView;
    (void)rowView;
    (void)rowIndex;
}

// GNUstep declares every delegate callback as required; the ones without
// behavior stay as explicit no-ops so the protocol contract is visible.
- (BOOL)outlineView:(NSOutlineView *)outlineView
    shouldCollapseItem:(id)item
{
    (void)outlineView;
    (void)item;
    return YES;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
     shouldEditTableColumn:(NSTableColumn *)tableColumn
                     item:(id)item
{
    (void)outlineView;
    (void)tableColumn;
    (void)item;
    return NO;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
    shouldExpandItem:(id)item
{
    (void)outlineView;
    (void)item;
    return YES;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
    shouldSelectItem:(id)item
{
    (void)outlineView;
    (void)item;
    return YES;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
    shouldSelectTableColumn:(NSTableColumn *)tableColumn
{
    (void)outlineView;
    (void)tableColumn;
    return NO;
}

// Cell-based customization is unused; the view-based path above is the
// only presentation channel.
- (void)outlineView:(NSOutlineView *)outlineView
    willDisplayCell:(id)cell
     forTableColumn:(NSTableColumn *)tableColumn
               item:(id)item
{
    (void)outlineView;
    (void)cell;
    (void)tableColumn;
    (void)item;
}

- (NSCell *)outlineView:(NSOutlineView *)outlineView
      dataCellForTableColumn:(NSTableColumn *)tableColumn
                        item:(id)item
{
    (void)outlineView;
    (void)tableColumn;
    (void)item;
    return nil;
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView
        heightOfRowByItem:(id)item
{
    (void)outlineView;
    (void)item;
    return 20.0;
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView
        sizeToFitWidthOfColumn:(NSInteger)columnIndex
{
    (void)outlineView;
    (void)columnIndex;
    return 0.0;
}

- (void)outlineView:(NSOutlineView *)outlineView
    willDisplayOutlineCell:(id)cell
            forTableColumn:(NSTableColumn *)tableColumn
                      item:(id)item
{
    (void)outlineView;
    (void)cell;
    (void)tableColumn;
    (void)item;
}

- (BOOL)selectionShouldChangeInOutlineView:(NSOutlineView *)outlineView
{
    (void)outlineView;
    return YES;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
           shouldShowCellExpansionForTableColumn:(NSTableColumn *)tableColumn
                                            item:(id)item
{
    (void)outlineView;
    (void)tableColumn;
    (void)item;
    return NO;
}

- (NSString *)outlineView:(NSOutlineView *)outlineView
                   toolTipForCell:(NSCell *)cell
                     rect:(NSRectPointer)rect
              tableColumn:(NSTableColumn *)tableColumn
                     item:(id)item
            mouseLocation:(NSPoint)mouseLocation
{
    (void)outlineView;
    (void)cell;
    (void)rect;
    (void)tableColumn;
    (void)item;
    (void)mouseLocation;
    return nil;
}

- (void)outlineViewColumnDidMove:(NSNotification *)aNotification
{
    (void)aNotification;
}

- (void)outlineViewColumnDidResize:(NSNotification *)aNotification
{
    (void)aNotification;
}

- (void)outlineViewItemDidCollapse:(NSNotification *)aNotification
{
    (void)aNotification;
}

- (void)outlineViewItemDidExpand:(NSNotification *)aNotification
{
    (void)aNotification;
}

- (void)outlineViewItemWillCollapse:(NSNotification *)aNotification
{
    (void)aNotification;
}

- (void)outlineViewItemWillExpand:(NSNotification *)aNotification
{
    (void)aNotification;
}

- (void)outlineViewSelectionIsChanging:(NSNotification *)aNotification
{
    (void)aNotification;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    [self notifySelection:self.selectedObject];
}

- (void)notifySelection:(DUStorageObject *)object
{
    if ([self.delegate respondsToSelector:@selector(browserSelectionChanged:)]) {
        [self.delegate browserSelectionChanged:object];
    }
}

#pragma mark - Context menu (SPEC section 33)

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSPoint point = [self.outlineView convertPoint:event.locationInWindow
                                          fromView:nil];
    NSInteger row = [self.outlineView rowAtPoint:point];
    if (row < 0 || row >= (NSInteger)self.visibleObjects.count) {
        return nil;
    }
    [self.outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                  byExtendingSelection:NO];

    DUStorageObject *object = [self.outlineView itemAtRow:row];
    DUStorageCapabilities *caps = object.capabilities;

    NSMenu *menu = [[NSMenu alloc] init];
    void (^add)(NSString *, NSString *) =
        ^(NSString *title, NSString *token) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                          action:nil
                                                   keyEquivalent:@""];
            item.representedObject = token;
            item.target = self;
            item.action = @selector(contextCommand:);
            [menu addItem:item];
        };

    add(NSLocalizedString(@"Get Information", nil), @"info");
    if (caps.canVerify) {
        add(NSLocalizedString(@"Verify", nil), @"verify");
    }
    if (caps.canRepair) {
        add(NSLocalizedString(@"Repair", nil), @"repair");
    }
    if (caps.canMount) {
        add(NSLocalizedString(@"Mount", nil), @"mount");
    }
    if (caps.canUnmount) {
        add(NSLocalizedString(@"Unmount", nil), @"unmount");
    }
    if (caps.canErase) {
        add(NSLocalizedString(@"Erase", nil), @"erase");
    }
    if (caps.canBurn) {
        add(NSLocalizedString(@"Burn", nil), @"burn");
    }
    if (caps.canEject) {
        add(NSLocalizedString(@"Eject", nil), @"eject");
    }
    return [menu numberOfItems] > 0 ? menu : nil;
}

- (void)contextCommand:(NSMenuItem *)sender
{
    DUStorageObject *object = self.selectedObject;
    if (object != nil) {
        [self.delegate browserRequestCommand:sender.representedObject
                                   forObject:object];
    }
}

#pragma mark - NSOutlineView data source

- (NSInteger)outlineView:(NSOutlineView *)outlineView
              numberOfChildrenOfItem:(id)item
{
    (void)outlineView;
    if (item == nil) {
        return self.storageManager.currentObjects.count;
    }
    return [(DUStorageObject *)item children].count;
}

- (id)outlineView:(NSOutlineView *)outlineView
             child:(NSInteger)index
            ofItem:(id)item
{
    (void)outlineView;
    return item == nil
        ? self.storageManager.currentObjects[index]
        : [(DUStorageObject *)item children][index];
}

// GNUstep declares these as required protocol members even though this
// browser is entirely view-based; provide honest minimal implementations.
- (id)outlineView:(NSOutlineView *)outlineView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
                       byItem:(id)item
{
    (void)outlineView;
    (void)tableColumn;
    return [(DUStorageObject *)item displayName] ?: @"";
}

// Editing is not offered in the browser; refuse writes.
- (void)outlineView:(NSOutlineView *)outlineView
     setObjectValue:(id)object
      forTableColumn:(NSTableColumn *)tableColumn
               byItem:(id)item
{
    (void)outlineView;
    (void)object;
    (void)tableColumn;
    (void)item;
}

- (id)outlineView:(NSOutlineView *)outlineView
      itemForPersistentObject:(id)persistentObject
{
    (void)outlineView;
    return [self storageObjectForVisibleIdentifier:persistentObject];
}

- (id)outlineView:(NSOutlineView *)outlineView
    persistentObjectForItem:(id)item
{
    (void)outlineView;
    return [(DUStorageObject *)item identifier];
}

// The tree is always presented in discovery order; sorting is refused.
- (void)outlineView:(NSOutlineView *)outlineView
    sortDescriptorsDidChange:(NSArray *)sortDescriptors
{
    (void)outlineView;
    (void)sortDescriptors;
}

// Promised-file drag destinations are not offered by this browser.
- (NSArray *)outlineView:(NSOutlineView *)outlineView
namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination
          forDraggedItems:(NSArray *)items
{
    (void)outlineView;
    (void)dropDestination;
    (void)items;
    return nil;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
         writeItems:(NSArray *)items
        toPasteboard:(NSPasteboard *)pasteboard
{
    // Drag sources are not offered; nothing is ever written.
    (void)outlineView;
    (void)items;
    (void)pasteboard;
    return NO;
}

- (NSDragOperation)outlineView:(NSOutlineView *)outlineView
                   validateDrop:(id<NSDraggingInfo>)info
                    proposedItem:(id)item
              proposedChildIndex:(NSInteger)index
{
    (void)outlineView;
    (void)item;
    (void)index;
    // Only file drops that contain at least one disk-image file are accepted;
    // everything else is refused so the pane does not advertise a drop it
    // cannot honor.
    NSArray<NSURL *> *urls =
        [self imageFileURLsFromPasteboard:[info draggingPasteboard]];
    return urls.count > 0 ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
            acceptDrop:(id<NSDraggingInfo>)info
                  item:(id)item
              childIndex:(NSInteger)index
{
    (void)outlineView;
    (void)item;
    (void)index;
    NSArray<NSURL *> *urls =
        [self imageFileURLsFromPasteboard:[info draggingPasteboard]];
    if (urls.count == 0) {
        return NO;
    }
    if ([self.delegate
            respondsToSelector:@selector(browserDidDropImageFiles:)]) {
        [self.delegate browserDidDropImageFiles:urls];
    }
    return YES;
}

#pragma mark - Image-file drop helpers

+ (NSSet<NSString *> *)diskImagePathExtensions
{
    // Extensions we treat as mountable disk images.  Kept broad so the common
    // raw and virtualization formats are accepted when dropped from Workspace.
    static NSSet<NSString *> *extensions = nil;
    if (extensions == nil) {
        extensions = [NSSet
            setWithObjects:@"img", @"dmg", @"iso", @"raw", @"qcow",
                           @"qcow2", @"vdi", @"vmdk", @"vhd", @"vhdx",
                           @"hdd", @"cdr", @"toast", @"sparseimage", @"bin",
                           @"cue", @"nrg", nil];
    }
    return extensions;
}

- (NSArray<NSURL *> *)imageFileURLsFromPasteboard:(NSPasteboard *)pasteboard
{
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    // The Workspace file-manager drag carries absolute paths under
    // NSFilenamesPboardType (and sometimes NSURLPboardType); read whichever
    // is present.
    NSArray *entries = [pasteboard propertyListForType:NSFilenamesPboardType];
    if (entries == nil) {
        entries = [pasteboard propertyListForType:NSURLPboardType];
    }
    for (id entry in entries) {
        NSURL *url = nil;
        if ([entry isKindOfClass:[NSString class]]) {
            if ([(NSString *)entry rangeOfString:@"://"].location !=
                NSNotFound) {
                url = [NSURL URLWithString:entry];
            } else {
                url = [NSURL fileURLWithPath:entry];
            }
        } else if ([entry isKindOfClass:[NSURL class]]) {
            url = entry;
        }
        if (url == nil || ![url isFileURL]) {
            continue;
        }
        NSString *ext = [[url pathExtension] lowercaseString];
        if ([[[self class] diskImagePathExtensions] containsObject:ext]) {
            [urls addObject:url];
        }
    }
    return urls;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
       isItemExpandable:(id)item
{
    (void)outlineView;
    return [(DUStorageObject *)item children].count > 0;
}

#pragma mark - NSOutlineView delegate

- (NSView *)outlineView:(NSOutlineView *)outlineView
         viewForTableColumn:(NSTableColumn *)tableColumn
                      item:(id)item
{
    (void)outlineView;
    (void)tableColumn;
    DUStorageObject *object = item;

    // Icon + label cell built once and reconfigured on reuse.
    // GNUstep returns a plain view here; the cast documents our contract
    // that only cells we built ourselves are reused.
    NSTableCellView *cell = (NSTableCellView *)
        [self.outlineView makeViewWithIdentifier:kColumnIdentifier owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = kColumnIdentifier;

        NSImageView *imageView = [[NSImageView alloc] initWithFrame:
            NSMakeRect(2, 2, 16, 16)];
        imageView.imageScaling = NSImageScaleProportionallyDown;
        imageView.autoresizingMask = NSViewMinYMargin | NSViewMaxYMargin;
        imageView.tag = 1;
        [cell addSubview:imageView];
        cell.imageView = imageView;

        NSTextField *textField = [[NSTextField alloc] initWithFrame:
            NSMakeRect(22, 3, 150, 14)];
        textField.editable = NO;
        textField.bezeled = NO;
        textField.drawsBackground = NO;
        textField.autoresizingMask =
            NSViewWidthSizable | NSViewMinYMargin;
        textField.font = [NSFont systemFontOfSize:11];
        [(NSCell *)textField.cell
            setLineBreakMode:NSLineBreakByTruncatingTail];
        textField.tag = 2;
        [cell addSubview:textField];
        cell.textField = textField;
    }

    cell.textField.stringValue = object.displayName ?: @"";
    cell.imageView.image = [self iconForType:object.type];
    return cell;
}

- (NSImage *)iconForType:(DUStorageObjectType)type
{
    NSString *name = nil;
    switch (type) {
        case DUStorageObjectTypeDevice: {
            name = @"disk";
            break;
        }
        case DUStorageObjectTypePartition:
        case DUStorageObjectTypeVolume: {
            name = @"volume";
            break;
        }
        case DUStorageObjectTypeOpticalMedia: {
            name = @"media";
            break;
        }
        case DUStorageObjectTypeDiskImage: {
            name = @"image";
            break;
        }
        case DUStorageObjectTypeRAIDSet: {
            name = @"raid";
            break;
        }
    }
    if (name == nil) {
        return nil;
    }
    return [DUIcons iconNamed:name];
}

@end
