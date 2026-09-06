/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUNewImageController.h"
#import "DUStorageDevice.h"

#import "AppearanceMetrics.h"
#import "DUErrors.h"
#import "DUOperation.h"
#import "DUNotifications.h"
#import "DUOperationLogView.h"
#import "DUParsing.h"
#import "DUStorageBackend.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"

@interface DUNewImageController ()
@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong) DUOperationLogView *logView;

@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextField *sourceField;
/* The image source: always the outline's current selection. */
@property (nonatomic, strong) DUStorageObject *sourceObject;
@property (nonatomic, strong) NSTextField *pathField;
@property (nonatomic, strong) NSButton *browseButton;
@property (nonatomic, strong) NSPopUpButton *formatPopup;
@property (nonatomic, strong) NSButton *createButton;
@property (nonatomic, strong) NSButton *cancelButton;

// Polled by the backend worker per chunk so cancellation takes effect
// without waiting for the copy to finish.
@property (nonatomic, weak) DUOperation *runningOperation;
@end

@implementation DUNewImageController

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
    return self;
}

#pragma mark - Panel construction

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

- (NSPanel *)buildPanel
{
    CGFloat width = 460.0;
    CGFloat height = 250.0;
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, width, height)
                      styleMask:NSTitledWindowMask
                        backing:NSBackingStoreBuffered
                          defer:NO];
    panel.title = NSLocalizedString(@"New Disk Image", nil);
    NSView *content = panel.contentView;

    // Source row.
    NSTextField *sourceLabel =
        [self label:NSLocalizedString(@"Source:", nil)];
    sourceLabel.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                   height - METRICS_CONTENT_TOP_MARGIN -
                       METRICS_BUTTON_HEIGHT,
                   80, METRICS_BUTTON_HEIGHT);
    [content addSubview:sourceLabel];

    /* Read-only reflection of the outline selection: the source is never
     * chosen here (a candidate popup invited imaging the wrong disk). */
    _sourceField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(
                           METRICS_CONTENT_SIDE_MARGIN + 90,
                           height - METRICS_CONTENT_TOP_MARGIN -
                               METRICS_BUTTON_HEIGHT,
                           width - METRICS_CONTENT_SIDE_MARGIN - 90 -
                               METRICS_CONTENT_SIDE_MARGIN,
                           METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    _sourceField.editable = NO;
    _sourceField.bezeled = YES;
    [_sourceField setSelectable: NO];
    _sourceField.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [content addSubview:_sourceField];

    // Destination row.
    CGFloat destY =
        sourceLabel.frame.origin.y - METRICS_TEXT_INPUT_FIELD_HEIGHT -
        METRICS_SPACE_16;
    NSTextField *destLabel = [self label:NSLocalizedString(@"Save As:", nil)];
    destLabel.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, destY, 80,
                   METRICS_TEXT_INPUT_FIELD_HEIGHT);
    [content addSubview:destLabel];

    _pathField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(
                           METRICS_CONTENT_SIDE_MARGIN + 90,
                           destY,
                           width - METRICS_CONTENT_SIDE_MARGIN - 90 - 90 -
                               METRICS_SPACE_12,
                           METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    [content addSubview:_pathField];

    _browseButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(width - METRICS_CONTENT_SIDE_MARGIN - 90,
                                 destY, 90, METRICS_BUTTON_SMALL_HEIGHT)];
    _browseButton.title = NSLocalizedString(@"Browse...", nil);
    _browseButton.bezelStyle = NSRoundedBezelStyle;
    [_browseButton sizeToFit];
    [_browseButton setTarget:self];
    [_browseButton setAction:@selector(browseClicked:)];
    [content addSubview:_browseButton];

    // Format row.
    CGFloat formatY = destY - METRICS_BUTTON_HEIGHT - METRICS_SPACE_16;
    NSTextField *formatLabel =
        [self label:NSLocalizedString(@"Format:", nil)];
    formatLabel.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, formatY, 80,
                   METRICS_BUTTON_HEIGHT);
    [content addSubview:formatLabel];

    _formatPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(
                           METRICS_CONTENT_SIDE_MARGIN + 90,
                           formatY,
                           width - METRICS_CONTENT_SIDE_MARGIN - 90 -
                               METRICS_CONTENT_SIDE_MARGIN,
                           METRICS_BUTTON_HEIGHT)];
    [content addSubview:_formatPopup];

    // Button row: Cancel left of Create at lower right (HIG default).
    CGFloat buttonY = METRICS_CONTENT_BOTTOM_MARGIN;
    _createButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(width - METRICS_CONTENT_SIDE_MARGIN - 100,
                                 buttonY, 100, METRICS_BUTTON_HEIGHT)];
    _createButton.title = NSLocalizedString(@"Create", nil);
    _createButton.bezelStyle = NSRoundedBezelStyle;
    _createButton.keyEquivalent = @"\r";
    [_createButton setTarget:self];
    [_createButton setAction:@selector(createClicked:)];
    [content addSubview:_createButton];

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

#pragma mark - Content

// Eligible sources: whole devices and individual partitions/volumes that
// report a byte size; optical media stays out (read-only oddities).
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

- (void)setSourceObject:(DUStorageObject *)object
{
    _sourceObject = object;
    if (_sourceField != nil)
      {
        NSString *path = object.backendPath ?: @"";
        _sourceField.stringValue =
            [NSString stringWithFormat:@"%@ (%@)",
                 object.displayName
                     ?: NSLocalizedString(@"Nothing selected", nil),
                 path];
      }
}

- (void)openPanel
{
    if (_panel == nil) {
        _panel = [self buildPanel];
    }
    [self setSourceObject:_sourceObject];
    [self fillFormats];

    // Suggest a destination name from the selection.
    DUStorageObject *source = self.selectedSource;
    if (source != nil && _pathField.stringValue.length == 0) {
        NSString *name = source.displayName
            ?: NSLocalizedString(@"disk", nil);
        // Keep only alphanumerics so the suggested file name is portable.
        NSString *base = [[name componentsSeparatedByCharactersInSet:
                                     [[NSCharacterSet alphanumericCharacterSet]
                                         invertedSet]]
            componentsJoinedByString:@""];
        if (base.length == 0) {
            base = NSLocalizedString(@"disk", nil);
        }
        _pathField.stringValue =
            [NSString stringWithFormat:@"~/Documents/%@.img", base];
    }

    [_panel center];
    // Non-modal on purpose: image creation takes minutes and a modal
    // session would freeze the whole application for its duration
    // (ARCHITECTURE.md section 31). Progress reports flow to the operation
    // log and the main window's status strip instead.
    [_panel makeKeyAndOrderFront:nil];
}

- (DUStorageObject *)selectedSource
{
    return _sourceObject;
}

#pragma mark - Actions

- (void)browseClicked:(id)sender
{
    (void)sender;
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

- (void)createClicked:(id)sender
{
    (void)sender;
    DUStorageObject *source = self.selectedSource;
    NSString *path = _pathField.stringValue;
    NSMenuItem *formatItem = (NSMenuItem *)_formatPopup.selectedItem;
    NSString *format = objc_getAssociatedObject(formatItem, "duFormatId");

    if (source == nil || path.length == 0 || format.length == 0) {
        NSRunAlertPanel(
            NSLocalizedString(@"New Disk Image", nil),
            NSLocalizedString(
                @"Please choose a source, a destination file and a format.",
                nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }

    // Refuse silently overwriting through the manual path field as well;
    // the backend double-checks, but users should not be surprised.
    if ([[NSFileManager defaultManager] fileExistsAtPath:
                       [path stringByExpandingTildeInPath]]) {
        NSInteger choice = NSRunAlertPanel(
            NSLocalizedString(@"New Disk Image", nil),
            [NSString stringWithFormat:NSLocalizedString(
                                            @"%@ already exists. Overwrite it?", nil),
                                       path.lastPathComponent],
            NSLocalizedString(@"Cancel", nil),
            NSLocalizedString(@"Overwrite", nil), nil);
        if (choice != NSAlertAlternateReturn) {
            return;
        }
        [[NSFileManager defaultManager] removeItemAtPath:
                            [path stringByExpandingTildeInPath]
                                                  error:NULL];
    }

    // The cancel probe travels with the options; the backend polls it per
    // chunk so Stop (from the main window's status strip) takes effect
    // within a second even on huge devices. Weak self: the options live as
    // long as the operation, which must not retain the controller.
    __weak typeof(self) weakSelf = self;
    NSDictionary *options = @{
        @"path" : path,
        @"format" : format,
        @"duCancelCheck" : ^BOOL(void) {
            return weakSelf.runningOperation.cancelRequested;
        },
    };

    void (^progressBlock)(double, NSString *) =
        ^(double value, NSString *message) {
            // Worker thread -> main thread marshaling; the log view is
            // thread-safe and the main window's strip listens to operation
            // notifications on its own.
            [weakSelf performSelectorOnMainThread:
                            @selector(updateProgressWithFraction:message:)
                                withObject:@[ @(value), message ?: @"" ]
                              waitUntilDone:NO];
        };
    void (^completionBlock)(NSError *) =
        ^(NSError *error) {
            [weakSelf performSelectorOnMainThread:
                            @selector(finishImageCreationWithError:)
                                withObject:error ?: [NSNull null]
                              waitUntilDone:NO];
        };

    NSError *error = nil;
    DUOperation *operation =
        [self.storageManager createImageFromObject:source
                                            options:options
                                         onProgress:progressBlock
                                       onCompletion:completionBlock
                                              error:&error];
    if (operation == nil) {
        [self.logView appendLine:error.localizedDescription ?: @""];
        return;
    }
    self.runningOperation = operation;
    [self.logView appendLine:[NSString stringWithFormat:
        NSLocalizedString(@"Creating image of %@ to %@...",
                          nil),
        source.displayName ?: @"", path]];

    // Hand the work back and close the input form; the operation continues
    // in the background with progress in the main window.
    [_panel orderOut:nil];
}

- (void)updateProgressWithFraction:(NSArray *)payload
{
    double fraction = [payload.firstObject doubleValue];
    NSString *message = payload.count > 1 ? payload[1] : @"";
    [self.logView appendLine:
        [NSString stringWithFormat:@"(%.0f%%) %@",
                                   fraction * 100.0, message]];
}

- (void)finishImageCreationWithError:(NSError *)error
{
    if ([NSNull null] == (id)error || error == nil) {
        [self.logView appendLine:NSLocalizedString(
                                      @"Image created successfully.", nil)];
    } else if (error.code == DUErrorCancelled) {
        [self.logView appendLine:NSLocalizedString(@"Cancelled.", nil)];
    } else {
        [self.logView appendLine:error.localizedDescription
              ?: NSLocalizedString(@"Image creation failed.", nil)];
        NSRunAlertPanel(
            NSLocalizedString(@"New Disk Image", nil),
            error.localizedDescription
                ?: NSLocalizedString(@"Image creation failed.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
    }
    self.runningOperation = nil;
}

@end
