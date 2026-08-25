/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUImagePanelController.h"

#import <objc/runtime.h>

#import "AppearanceMetrics.h"
#import "DUDiskImage.h"
#import "DUErrors.h"
#import "DUOperation.h"
#import "DUOperationLogView.h"
#import "DUParsing.h"
#import "DUStorageDevice.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"

@interface DUImagePanelController ()
@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong) DUOperationLogView *logView;
@property (nonatomic, assign) DUImagePanelMode mode;

@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextField *sourceLabel;
@property (nonatomic, strong) NSTextField *sourceField;
@property (nonatomic, strong) NSTextField *formatLabel;
@property (nonatomic, strong) NSPopUpButton *formatPopup;
@property (nonatomic, strong) NSTextField *pathLabel;
@property (nonatomic, strong) NSTextField *pathField;
@property (nonatomic, strong) NSButton *browseButton;
@property (nonatomic, strong) NSTextField *currentLabel;
@property (nonatomic, strong) NSTextField *currentField;
@property (nonatomic, strong) NSTextField *sizeLabel;
@property (nonatomic, strong) NSTextField *sizeField;
@property (nonatomic, strong) NSButton *primaryButton;
@property (nonatomic, strong) NSButton *cancelButton;

@property (nonatomic, weak) DUStorageObject *sourceObject;
@property (nonatomic, weak) DUOperation *runningOperation;
@end

@implementation DUImagePanelController

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
    _mode = DUImagePanelModeConvert;
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

#pragma mark - Panel construction

- (NSPanel *)buildPanel
{
    CGFloat width = 460.0;
    CGFloat height = 250.0;
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, width, height)
                      styleMask:NSTitledWindowMask
                        backing:NSBackingStoreBuffered
                          defer:NO];
    NSView *content = panel.contentView;

    CGFloat rowY = height - METRICS_CONTENT_TOP_MARGIN -
                   METRICS_BUTTON_HEIGHT;

    // Row 1: read-only source reflection (image or optical drive).
    _sourceLabel = [self label:NSLocalizedString(@"Source:", nil)];
    _sourceLabel.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, rowY, 80,
                   METRICS_BUTTON_HEIGHT);
    [content addSubview:_sourceLabel];

    _sourceField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(
                           METRICS_CONTENT_SIDE_MARGIN + 90,
                           rowY,
                           width - METRICS_CONTENT_SIDE_MARGIN - 90 -
                               METRICS_CONTENT_SIDE_MARGIN,
                           METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    _sourceField.editable = NO;
    _sourceField.bezeled = YES;
    [_sourceField setSelectable:NO];
    _sourceField.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [content addSubview:_sourceField];

    /* Slot 2: destination path (convert/burn) or current size (resize).
     * Slot 3: format popup (convert) or new size (resize). Each mode
     * shows one control per slot, so rows never overlap. */
    rowY -= METRICS_TEXT_INPUT_FIELD_HEIGHT + METRICS_SPACE_16;
    CGFloat slot2Y = rowY;
    rowY -= METRICS_TEXT_INPUT_FIELD_HEIGHT + METRICS_SPACE_16;
    CGFloat slot3Y = rowY;

    _pathLabel = [self label:NSLocalizedString(@"Save As:", nil)];
    _pathLabel.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, slot2Y, 80,
                   METRICS_TEXT_INPUT_FIELD_HEIGHT);
    [content addSubview:_pathLabel];

    _pathField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(
                           METRICS_CONTENT_SIDE_MARGIN + 90,
                           slot2Y,
                           width - METRICS_CONTENT_SIDE_MARGIN - 90 - 90 -
                               METRICS_SPACE_12,
                           METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    [content addSubview:_pathField];

    _browseButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(width - METRICS_CONTENT_SIDE_MARGIN - 90,
                                 slot2Y, 90, METRICS_BUTTON_SMALL_HEIGHT)];
    _browseButton.title = NSLocalizedString(@"Browse...", nil);
    _browseButton.bezelStyle = NSRoundedBezelStyle;
    [_browseButton sizeToFit];
    [_browseButton setTarget:self];
    [_browseButton setAction:@selector(browseClicked:)];
    [content addSubview:_browseButton];

    _formatLabel = [self label:NSLocalizedString(@"Format:", nil)];
    _formatLabel.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, slot3Y, 80,
                   METRICS_BUTTON_HEIGHT);
    [content addSubview:_formatLabel];

    _formatPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(
                           METRICS_CONTENT_SIDE_MARGIN + 90,
                           slot3Y,
                           width - METRICS_CONTENT_SIDE_MARGIN - 90 -
                               METRICS_CONTENT_SIDE_MARGIN,
                           METRICS_BUTTON_HEIGHT)];
    [content addSubview:_formatPopup];

    _currentLabel = [self label:NSLocalizedString(@"Current Size:", nil)];
    _currentLabel.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, slot2Y, 110,
                   METRICS_TEXT_INPUT_FIELD_HEIGHT);
    [content addSubview:_currentLabel];

    _currentField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(
                           METRICS_CONTENT_SIDE_MARGIN + 120,
                           slot2Y,
                           width - METRICS_CONTENT_SIDE_MARGIN - 120 -
                               METRICS_CONTENT_SIDE_MARGIN,
                           METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    _currentField.editable = NO;
    _currentField.bezeled = NO;
    _currentField.drawsBackground = NO;
    _currentField.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [content addSubview:_currentField];

    // Row 3: only the resize mode uses a third input row.
    rowY -= METRICS_TEXT_INPUT_FIELD_HEIGHT + METRICS_SPACE_16;
    _sizeLabel = [self label:NSLocalizedString(@"New Size:", nil)];
    _sizeLabel.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, rowY, 110,
                   METRICS_TEXT_INPUT_FIELD_HEIGHT);
    [content addSubview:_sizeLabel];

    NSTextField *sizeField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(
                           METRICS_CONTENT_SIDE_MARGIN + 120,
                           rowY,
                           width - METRICS_CONTENT_SIDE_MARGIN - 120 -
                               METRICS_CONTENT_SIDE_MARGIN,
                           METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    _sizeField = sizeField;
    [content addSubview:sizeField];

    // Button row: Cancel left of the primary action at lower right.
    CGFloat buttonY = METRICS_CONTENT_BOTTOM_MARGIN;
    _primaryButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(width - METRICS_CONTENT_SIDE_MARGIN - 100,
                                 buttonY, 100, METRICS_BUTTON_HEIGHT)];
    _primaryButton.bezelStyle = NSRoundedBezelStyle;
    _primaryButton.keyEquivalent = @"\r";
    [_primaryButton setTarget:self];
    [_primaryButton setAction:@selector(primaryClicked:)];
    [content addSubview:_primaryButton];

    _cancelButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(width - METRICS_CONTENT_SIDE_MARGIN -
                                     100 - METRICS_BUTTON_HORIZ_INTERSPACE -
                                     100,
                                 buttonY, 100, METRICS_BUTTON_HEIGHT)];
    _cancelButton.title = NSLocalizedString(@"Cancel", nil);
    _cancelButton.bezelStyle = NSRoundedBezelStyle;
    _cancelButton.keyEquivalent = @"\033";
    [_cancelButton setTarget:self];
    [_cancelButton setAction:@selector(cancelClicked:)];
    [content addSubview:_cancelButton];

    return panel;
}

// Mode-dependent visibility; the unused controls hide instead of being
// rebuilt so the panel keeps its geometry across mode switches.
- (void)applyModeToPanel
{
    if (_panel == nil) {
        return;
    }
    BOOL convert = _mode == DUImagePanelModeConvert;
    BOOL resize = _mode == DUImagePanelModeResize;
    BOOL burn = _mode == DUImagePanelModeBurn;

    _panel.title =
        convert ? NSLocalizedString(@"Convert Image", nil)
                : resize ? NSLocalizedString(@"Resize Image", nil)
                         : NSLocalizedString(@"Burn Image", nil);
    _primaryButton.title =
        convert ? NSLocalizedString(@"Convert", nil)
                : resize ? NSLocalizedString(@"Resize", nil)
                         : NSLocalizedString(@"Burn", nil);

    _sourceLabel.stringValue =
        burn ? NSLocalizedString(@"Target Drive:", nil)
             : NSLocalizedString(@"Source:", nil);

    [_pathLabel setHidden:!(convert || burn)];
    [_pathField setHidden:_pathLabel.isHidden];
    [_browseButton setHidden:_pathLabel.isHidden];
    _pathLabel.stringValue =
        burn ? NSLocalizedString(@"Image File:", nil)
             : NSLocalizedString(@"Save As:", nil);

    [_formatLabel setHidden:!convert];
    [_formatPopup setHidden:!convert];

    [_currentLabel setHidden:!resize];
    [_currentField setHidden:!resize];

    // Row 3 (New Size) is only meaningful for resize.
    [_sizeLabel setHidden:!resize];
    [_sizeField setHidden:!resize];
}

#pragma mark - Content

- (void)fillFormats
{
    [_formatPopup removeAllItems];
    NSArray<NSDictionary *> *formats =
        [self.storageManager imageCreationFormats];
    for (NSDictionary *format in formats) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:format[kDUFormatDisplayNameKey]
                   action:nil
            keyEquivalent:@""];
        objc_setAssociatedObject(item, "duFormatId",
                                 format[kDUFormatIdentifierKey],
                                 OBJC_ASSOCIATION_COPY);
        [_formatPopup.menu addItem:item];
    }
    if (_formatPopup.itemArray.count > 0) {
        [_formatPopup selectItemAtIndex:0];
    }
}

#pragma mark - Public entry

- (void)setMode:(DUImagePanelMode)mode
{
    _mode = mode;
    [self applyModeToPanel];
}

- (void)setSourceObject:(DUStorageObject *)object
{
    _sourceObject = object;
    if (_sourceField == nil) {
        return;
    }
    NSString *title = object.displayName
        ?: NSLocalizedString(@"Nothing selected", nil);
    if (_mode == DUImagePanelModeBurn) {
        NSString *node = [object isKindOfClass:[DUStorageDevice class]]
            ? (((DUStorageDevice *)object).devicePath
               ?: object.backendPath ?: @"")
            : @"";
        _sourceField.stringValue =
            [NSString stringWithFormat:@"%@ (%@)", title, node];
        return;
    }
    NSString *path = [object isKindOfClass:[DUDiskImage class]]
        ? ((DUDiskImage *)object).path ?: @""
        : @"";
    _sourceField.stringValue =
        [NSString stringWithFormat:@"%@ (%@)", title, path];
    if (_mode == DUImagePanelModeResize) {
        unsigned long long bytes = [object isKindOfClass:[DUDiskImage class]]
            ? ((DUDiskImage *)object).sizeBytes : 0;
        _currentField.stringValue =
            [NSString stringWithFormat:@"%@ (%llu bytes)",
                 [DUParsing humanReadableSizeFromBytes:bytes], bytes];
    }
}

- (void)openPanel
{
    if (_panel == nil) {
        _panel = [self buildPanel];
    }
    [self applyModeToPanel];
    [self setSourceObject:_sourceObject];
    if (_mode == DUImagePanelModeConvert) {
        [self fillFormats];
        _pathField.stringValue = @"";
    }
    if (_mode == DUImagePanelModeBurn) {
        _pathField.stringValue = @"";
    }

    [_panel center];
    // Non-modal on purpose: burning and converting take minutes and a
    // modal session would freeze the whole application for their duration
    // (ARCHITECTURE.md section 31).
    [_panel makeKeyAndOrderFront:nil];
}

#pragma mark - Helpers

// Parses "1073741824", "500 MB", "1.5 GiB", "2 GB" style sizes. Returns
// -1 when the text is not a positive size.
+ (long long)parseSizeBytes:(NSString *)text
{
    NSString *trimmed = [DUParsing trimmedString:text] ?: @"";
    if (trimmed.length == 0) {
        return -1;
    }
    NSCharacterSet *letters =
        [NSCharacterSet letterCharacterSet];
    NSRange unitRange = [trimmed rangeOfCharacterFromSet:letters];
    NSString *numberPart =
        unitRange.location == NSNotFound
            ? trimmed
            : [trimmed substringToIndex:unitRange.location];
    NSString *unitPart =
        unitRange.location == NSNotFound
            ? @""
            : [[trimmed substringFromIndex:unitRange.location]
                  stringByReplacingOccurrencesOfString:@" "
                                            withString:@""].uppercaseString;
    double value = [numberPart doubleValue];
    if (value <= 0.0) {
        return -1;
    }
    double multiplier = 1.0;
    if ([unitPart isEqualToString:@"K"] ||
        [unitPart isEqualToString:@"KB"]) {
        multiplier = 1000.0;
    } else if ([unitPart isEqualToString:@"KIB"]) {
        multiplier = 1024.0;
    } else if ([unitPart isEqualToString:@"M"] ||
               [unitPart isEqualToString:@"MB"]) {
        multiplier = 1000.0 * 1000.0;
    } else if ([unitPart isEqualToString:@"MIB"]) {
        multiplier = 1024.0 * 1024.0;
    } else if ([unitPart isEqualToString:@"G"] ||
               [unitPart isEqualToString:@"GB"]) {
        multiplier = 1000.0 * 1000.0 * 1000.0;
    } else if ([unitPart isEqualToString:@"GIB"]) {
        multiplier = 1024.0 * 1024.0 * 1024.0;
    } else if ([unitPart isEqualToString:@"T"] ||
               [unitPart isEqualToString:@"TB"]) {
        multiplier = 1000.0 * 1000.0 * 1000.0 * 1000.0;
    } else if ([unitPart isEqualToString:@"TIB"]) {
        multiplier = 1024.0 * 1024.0 * 1024.0 * 1024.0;
    } else if (unitPart.length > 0) {
        return -1;
    }
    double bytes = value * multiplier;
    if (bytes < 1.0 || bytes > 9000000000000000.0) {
        return -1;
    }
    return (long long)bytes;
}

#pragma mark - Actions

- (void)browseClicked:(id)sender
{
    (void)sender;
    if (_mode == DUImagePanelModeBurn) {
        // Burn reads an existing image file.
        NSOpenPanel *openPanel = [NSOpenPanel openPanel];
        openPanel.canChooseFiles = YES;
        openPanel.canChooseDirectories = NO;
        openPanel.directoryURL =
            [NSURL fileURLWithPath:[@"~/Documents"
                stringByExpandingTildeInPath]];
        if ([openPanel runModal] == NSOKButton &&
            openPanel.URL.path.length > 0) {
            _pathField.stringValue = openPanel.URL.path;
        }
        return;
    }

    NSSavePanel *savePanel = [NSSavePanel savePanel];
    savePanel.allowedFileTypes =
        @[ @"img", @"gz", @"qcow2", @"vhd", @"vdi" ];
    savePanel.directoryURL =
        [NSURL fileURLWithPath:[@"~/Documents"
            stringByExpandingTildeInPath]];
    if ([savePanel runModal] != NSOKButton) {
        return;
    }
    if (savePanel.URL.path.length > 0) {
        _pathField.stringValue = savePanel.URL.path;
    }
}

- (void)cancelClicked:(id)sender
{
    (void)sender;
    // Input-only dismissal; no modal session is running.
    [_panel orderOut:nil];
}

- (void)primaryClicked:(id)sender
{
    (void)sender;
    switch (_mode) {
        case DUImagePanelModeConvert:
            [self convertClicked];
            break;
        case DUImagePanelModeResize:
            [self resizeClicked];
            break;
        case DUImagePanelModeBurn:
            [self burnClicked];
            break;
    }
}

- (void)convertClicked
{
    DUDiskImage *source = (DUDiskImage *)self.sourceObject;
    NSString *path = _pathField.stringValue;
    NSMenuItem *formatItem = (NSMenuItem *)_formatPopup.selectedItem;
    NSString *format =
        objc_getAssociatedObject(formatItem, "duFormatId");

    if (![source isKindOfClass:[DUDiskImage class]] ||
        ((DUDiskImage *)source).path.length == 0 ||
        path.length == 0 || format.length == 0) {
        NSRunAlertPanel(
            NSLocalizedString(@"Convert Image", nil),
            NSLocalizedString(
                @"Please choose a source image, a destination file and a "
                @"format.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:
                       [path stringByExpandingTildeInPath]]) {
        NSRunAlertPanel(
            NSLocalizedString(@"Convert Image", nil),
            NSLocalizedString(
                @"The destination file already exists. Please choose "
                @"another name.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }

    [self startOperation:^{
        return [self.storageManager convertImage:source
                                          options:@{ @"path" : path,
                                                     @"format" : format }
                                       onProgress:nil
                                     onCompletion:nil
                                            error:NULL];
    } verb:NSLocalizedString(@"Converting image...", nil)];
}

- (void)resizeClicked
{
    DUDiskImage *source = (DUDiskImage *)self.sourceObject;
    long long targetBytes =
        [DUImagePanelController parseSizeBytes:_sizeField.stringValue];

    if (![source isKindOfClass:[DUDiskImage class]] ||
        ((DUDiskImage *)source).path.length == 0) {
        NSRunAlertPanel(
            NSLocalizedString(@"Resize Image", nil),
            NSLocalizedString(@"Please choose a source image.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    // The resize input rides the path field's row in this mode.
    if (targetBytes < 0) {
        NSRunAlertPanel(
            NSLocalizedString(@"Resize Image", nil),
            NSLocalizedString(@"Please enter a size such as 20 GB or "
                               @"1073741824.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }

    long long delta =
        targetBytes - (long long)((DUDiskImage *)source).sizeBytes;
    if (delta == 0) {
        [_panel orderOut:nil];
        return;
    }

    [self startOperation:^{
        return [self.storageManager resizeImage:source
                                         options:@{
              @"deltaBytes" : @(delta)
          }
                                      onProgress:nil
                                    onCompletion:nil
                                           error:NULL];
    } verb:NSLocalizedString(@"Resizing image...", nil)];
}

- (void)burnClicked
{
    DUStorageDevice *drive = (DUStorageDevice *)self.sourceObject;
    NSString *imagePath = [_pathField.stringValue
        stringByExpandingTildeInPath];

    if (![drive isKindOfClass:[DUStorageDevice class]] || !drive.optical ||
        drive.devicePath.length == 0) {
        NSRunAlertPanel(
            NSLocalizedString(@"Burn Image", nil),
            NSLocalizedString(@"Please select an optical drive in the "
                               @"sidebar first.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    if (imagePath.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:imagePath]) {
        NSRunAlertPanel(
            NSLocalizedString(@"Burn Image", nil),
            NSLocalizedString(@"Please choose an existing image file.",
                              nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }

    // The backend reads image.path; a transient descriptor carries the
    // user-picked file without registering it in the catalog.
    DUDiskImage *image = [[DUDiskImage alloc]
        initWithIdentifier:@"burn-image"];
    image.displayName = imagePath.lastPathComponent;
    image.path = imagePath;

    [self startOperation:^{
        return [self.storageManager burnImage:image
                                     toObject:drive
                                   onProgress:nil
                                 onCompletion:nil
                                        error:NULL];
    } verb:NSLocalizedString(@"Burning image...", nil)];
}

// Common tail: start, log, dismiss. Progress reports flow through the
// manager's operation notifications to the main window's status strip and
// the shared operation log; the panel keeps no private plumbing.
- (void)startOperation:(DUOperation *(^)(void))starter
                  verb:(NSString *)verb
{
    NSError *error = nil;
    DUOperation *operation = starter();
    if (operation == nil) {
        [self.logView appendLine:error.localizedDescription ?: @""];
        return;
    }
    self.runningOperation = operation;
    [self.logView appendLine:verb];

    // Hand the work back and close the input form; the operation continues
    // in the background.
    [_panel orderOut:nil];
}

@end
