/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUInformationController.h"

#import "AppearanceMetrics.h"
#import "DUDiskImage.h"
#import "DUIcons.h"
#import "DUOpticalMedia.h"
#import "DUPartition.h"
#import "DUParsing.h"
#import "DUStorageDevice.h"
#import "DUStorageObject.h"
#import "DUStorageVolume.h"

// Unknown-value placeholder per ARCHITECTURE.md section 13.
static NSString * const kUnknownValue = @"-";

// The info grid is re-rendered in place on every selection/topology
// update. Without an opaque background each render would draw its labels
// over the pixels of the previous one, so text would accumulate into a
// smudged, ever-bolder mess.
@interface DUInfoAreaView : NSView
@end

@implementation DUInfoAreaView

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(self.bounds);
}

@end

@interface DUInfoTextField : NSTextField
@end

@implementation DUInfoTextField
@end

@interface DUInformationController ()
@property (nonatomic, strong, readwrite) NSView *view;
@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSMutableArray<NSView *> *fieldViews;
@end

@implementation DUInformationController

- (instancetype)init
{
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _fieldViews = [NSMutableArray array];
    _view = [[DUInfoAreaView alloc] initWithFrame:NSMakeRect(0, 0, 700, 120)];
    _view.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    return self;
}

#pragma mark - Presentation

- (void)setObject:(DUStorageObject *)object
{
    // Erase the whole area, including the frames of the subviews we are
    // about to remove: their old pixels must not survive the re-render.
    [_view setNeedsDisplay:YES];
    for (NSView *subview in _view.subviews) {
        [subview removeFromSuperview];
    }
    [_fieldViews removeAllObjects];
    if (object == nil) {
        return;
    }

    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    NSString *iconName = @"disk";

    switch (object.type) {
        case DUStorageObjectTypeDevice: {
            DUStorageDevice *device = (DUStorageDevice *)object;
            if (device.optical) {
                iconName = @"optical";
                DUOpticalMedia *media = (DUOpticalMedia *)device.children.firstObject;
                [self addOpticalRows:media device:device into:rows];
            } else {
                iconName = @"disk";
                [rows addObject:@[
                    NSLocalizedString(@"Device:", nil),
                    object.displayName ?: kUnknownValue
                ]];
                [rows addObject:@[
                    NSLocalizedString(@"Connection:", nil),
                    device.connectionType ?: kUnknownValue
                ]];
                [rows addObject:@[
                    NSLocalizedString(@"Connection Type:", nil),
                    device.connectionIsInternal
                        ? NSLocalizedString(@"Internal", nil)
                        : NSLocalizedString(@"External", nil)
                ]];
                [rows addObject:@[
                    NSLocalizedString(@"Capacity:", nil),
                    [DUParsing humanReadableSizeFromBytes:
                                     device.capacityBytes]
                ]];
                [rows addObject:@[
                    NSLocalizedString(@"Partition Scheme:", nil),
                    device.partitionScheme ?: kUnknownValue
                ]];
                [rows addObject:@[
                    NSLocalizedString(@"Read Status:", nil),
                    NSLocalizedString(@"Supported", nil)
                ]];
                [rows addObject:@[
                    NSLocalizedString(@"Write Status:", nil),
                    device.readOnly
                        ? NSLocalizedString(@"Read-only", nil)
                        : NSLocalizedString(@"Supported", nil)
                ]];
                [rows addObject:@[
                    NSLocalizedString(@"Health Status:", nil),
                    device.healthStatus ?: kUnknownValue
                ]];
                [rows addObject:@[
                    NSLocalizedString(@"SMART Status:", nil),
                    [DUStorageDevice localizedSmartStatus:device.smartStatus]
                ]];
            }
            break;
        }
        case DUStorageObjectTypeVolume:
        case DUStorageObjectTypePartition: {
            iconName = @"volume";
            DUStorageVolume *volume = nil;
            if ([object isKindOfClass:[DUStorageVolume class]]) {
                volume = (DUStorageVolume *)object;
            } else {
                volume = ((DUPartition *)object).volume;
            }
            if (volume == nil) {
                [rows addObject:@[
                    NSLocalizedString(@"Filesystem:", nil), kUnknownValue
                ]];
                break;
            }
            [rows addObject:@[
                NSLocalizedString(@"Mount Point:", nil),
                volume.mountPoint ?: NSLocalizedString(
                                          @"Not mounted", nil)
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Filesystem:", nil),
                volume.filesystemType ?: kUnknownValue
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Ownership:", nil),
                volume.ownersEnabled
                    ? NSLocalizedString(@"Enabled", nil)
                    : NSLocalizedString(@"Disabled", nil)
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Capacity:", nil),
                [DUParsing humanReadableSizeFromBytes:
                                 volume.capacityBytes]
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Available:", nil),
                volume.availableBytes != 0
                    ? [DUParsing humanReadableSizeFromBytes:
                                       volume.availableBytes]
                    : kUnknownValue
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Used:", nil),
                volume.usedBytes != 0
                    ? [DUParsing humanReadableSizeFromBytes:
                                       volume.usedBytes]
                    : kUnknownValue
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Files:", nil),
                volume.fileCount != NSNotFound
                    ? [NSString stringWithFormat:@"%lu",
                           (unsigned long)volume.fileCount]
                    : kUnknownValue
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Folders:", nil),
                volume.folderCount != NSNotFound
                    ? [NSString stringWithFormat:@"%lu",
                           (unsigned long)volume.folderCount]
                    : kUnknownValue
            ]];
            break;
        }
        case DUStorageObjectTypeOpticalMedia: {
            iconName = @"media";
            DUOpticalMedia *media = (DUOpticalMedia *)object;
            [self addOpticalRows:media device:nil into:rows];
            break;
        }
        case DUStorageObjectTypeDiskImage: {
            iconName = @"image";
            DUDiskImage *image = (DUDiskImage *)object;
            [rows addObject:@[
                NSLocalizedString(@"Image File:", nil),
                image.path ?: kUnknownValue
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Format:", nil),
                image.format ?: kUnknownValue
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Size:", nil),
                [DUParsing humanReadableSizeFromBytes:image.sizeBytes]
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Compressed:", nil),
                image.compressed ? NSLocalizedString(@"Yes", nil)
                                 : NSLocalizedString(@"No", nil)
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Encrypted:", nil),
                image.encrypted ? NSLocalizedString(@"Yes", nil)
                                : NSLocalizedString(@"No", nil)
            ]];
            [rows addObject:@[
                NSLocalizedString(@"Mounted:", nil),
                image.mounted ? NSLocalizedString(@"Yes", nil)
                              : NSLocalizedString(@"No", nil)
            ]];
            break;
        }
        case DUStorageObjectTypeRAIDSet: {
            iconName = @"raid";
            [rows addObject:@[
                NSLocalizedString(@"Device:", nil),
                object.displayName ?: kUnknownValue
            ]];
            break;
        }
    }

    [self renderRows:rows iconName:iconName];
}

- (void)addOpticalRows:(DUOpticalMedia *)media
                 device:(DUStorageDevice *)device
                   into:(NSMutableArray<NSArray<NSString *> *> *)rows
{
    if (device != nil) {
        [rows addObject:@[
            NSLocalizedString(@"Device:", nil),
            device.displayName ?: kUnknownValue
        ]];
    }
    if (media == nil) {
        [rows addObject:@[
            NSLocalizedString(@"Media:", nil),
            NSLocalizedString(@"No media present", nil)
        ]];
        return;
    }
    [rows addObject:@[
        NSLocalizedString(@"Media:", nil), media.displayName ?: kUnknownValue
    ]];
    [rows addObject:@[
        NSLocalizedString(@"Filesystem:", nil),
        media.filesystemType ?: kUnknownValue
    ]];
    [rows addObject:@[
        NSLocalizedString(@"Capacity:", nil),
        [DUParsing humanReadableSizeFromBytes:media.capacityBytes]
    ]];
    [rows addObject:@[
        NSLocalizedString(@"Used:", nil),
        [DUParsing humanReadableSizeFromBytes:media.usedBytes]
    ]];
    [rows addObject:@[
        NSLocalizedString(@"Free:", nil),
        [DUParsing humanReadableSizeFromBytes:media.freeBytes]
    ]];
    [rows addObject:@[
        NSLocalizedString(@"Writable:", nil),
        media.writable ? NSLocalizedString(@"Yes", nil)
                       : NSLocalizedString(@"No", nil)
    ]];
    [rows addObject:@[
        NSLocalizedString(@"Ejectable:", nil),
        media.ejectable ? NSLocalizedString(@"Yes", nil)
                        : NSLocalizedString(@"No", nil)
    ]];
}

// Two-column grid flowing left to right, wrapping into a second column of
// label/value pairs when the first fills up (SPEC section 22 example).
// The type icon sits in its own band above the grid so no row ever has to
// indent around it.
- (void)renderRows:(NSArray<NSArray<NSString *> *> *)rows
           iconName:(NSString *)iconName
{
    CGFloat width = NSWidth(_view.frame);
    CGFloat height = NSHeight(_view.frame);
    CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat rowHeight = METRICS_RADIO_BUTTON_SMALL_LINE_SPACING;
    CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;

    // Icon band consumes one row of vertical space.
    CGFloat gridTop = height - topMargin - 16.0 - METRICS_SPACE_8;

    // Wide footers flow two columns; the standalone information window is
    // narrow enough that two columns would truncate every value.
    NSInteger columnCount = width >= 520 ? 2 : 1;
    CGFloat gap = (columnCount == 2) ? METRICS_SPACE_24 : 0.0;
    CGFloat columnWidth =
        (width - 2 * side - gap * (columnCount - 1)) /
            (CGFloat)columnCount;

    NSInteger totalRows = (NSInteger)rows.count;
    NSInteger heightCapacity =
        (NSInteger)(floor((gridTop - METRICS_CONTENT_BOTTOM_MARGIN) /
                          rowHeight));
    if (heightCapacity < 1) {
        heightCapacity = 1;
    }
    // Two columns balance rows evenly; a single column simply fills down.
    NSInteger rowsPerColumn = (columnCount == 2)
        ? MIN(heightCapacity,
              (totalRows + 1) / 2)
        : heightCapacity;
    // Every row must fit into the columns we actually have: a grid taller
    // than heightCapacity squeezes toward the bottom margin instead of
    // spilling into a column that would sit outside the window.
    if (rowsPerColumn * columnCount < totalRows) {
        rowsPerColumn = (totalRows + columnCount - 1) / columnCount;
    }

    NSImage *icon = [DUIcons iconNamed:iconName];
    if (icon != nil) {
        NSImageView *imageView =
            [[NSImageView alloc] initWithFrame:NSMakeRect(
                                    side, height - topMargin - 16,
                                    16, 16)];
        imageView.image = icon;
        imageView.imageScaling = NSImageScaleProportionallyDown;
        [_view addSubview:imageView];
    }

    for (NSUInteger index = 0; index < rows.count; index++) {
        NSUInteger columnIndex = index / (NSUInteger)rowsPerColumn;
        NSUInteger rowIndex = index % (NSUInteger)rowsPerColumn;
        CGFloat x = side + columnIndex * (columnWidth + gap);
        CGFloat y =
            gridTop - (CGFloat)(rowIndex + 1) * rowHeight;

        NSArray<NSString *> *pair = rows[index];
        NSTextField *label = [self textLabel:pair[0] bold:YES];
        label.frame = NSMakeRect(x, y, columnWidth * 0.45, rowHeight);
        [_view addSubview:label];

        NSTextField *value = [self textLabel:pair[1] bold:NO];
        value.frame =
            NSMakeRect(x + columnWidth * 0.45, y,
                       columnWidth * 0.55, rowHeight);
        [_view addSubview:value];
    }
}

- (NSTextField *)textLabel:(NSString *)text bold:(BOOL)bold
{
    NSTextField *label = [[DUInfoTextField alloc] initWithFrame:NSZeroRect];
    label.editable = NO;
    label.bezeled = NO;
    /* Opaque on purpose: the area view behind us never participates in
     * partial redraws, so a transparent field would stack its glyphs onto
     * whatever pixels survived from earlier renders (observed as
     * double-struck values after operations). */
    label.drawsBackground = YES;
    label.backgroundColor = [NSColor controlBackgroundColor];
    label.stringValue = text.length > 0 ? text : kUnknownValue;
    label.font = bold ? METRICS_FONT_SYSTEM_BOLD_11
                      : METRICS_FONT_SYSTEM_REGULAR_11;
    [(NSCell *)label.cell setLineBreakMode:NSLineBreakByTruncatingTail];
    return label;
}

@end
