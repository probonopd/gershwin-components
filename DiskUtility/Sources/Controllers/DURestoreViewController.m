/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DURestoreViewController.h"

#import "AppearanceMetrics.h"
#import "DUDiskImage.h"
#import "DUStorageCapabilities.h"
#import "DUStorageVolume.h"
#import "DUErrors.h"
#import "DUOperation.h"
#import "DUOperationLogView.h"
#import "DUPaneView.h"
#import "DUOperationManager.h"
#import "DUNotifications.h"
#import "DUPartition.h"
#import "DURestoreOperation.h"
#import "DUStorageBackend.h"
#import "DUStorageDevice.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"

static NSString * const kDefaultsConfirmDestructive =
    @"DUConfirmDestructiveOperations";

@interface DURestoreViewController ()
@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong) DUOperationLogView *logView;
@property (nonatomic, strong, readwrite) NSView *view;

@property (nonatomic, strong) NSTextField *sourceLabel;
@property (nonatomic, strong) NSTextField *sourceField;
@property (nonatomic, strong) NSButton *sourceChooseButton;
@property (nonatomic, strong) NSTextField *destinationLabel;
@property (nonatomic, strong) NSTextField *destinationField;
@property (nonatomic, strong) NSButton *destinationChooseButton;
@property (nonatomic, strong) NSButton *eraseDestinationCheck;
@property (nonatomic, strong) NSButton *skipChecksumCheck;
@property (nonatomic, strong) NSButton *restoreButton;

@property (nonatomic, weak) DUStorageObject *currentObject;
// Resolved objects behind the text fields; the fields hold display strings.
@property (nonatomic, strong) DUStorageObject *resolvedSource;
@property (nonatomic, strong) DUStorageObject *resolvedDestination;
// YES once the user picked a destination explicitly; the selection
// convenience preselect then stops overriding it.
@property (nonatomic, assign) BOOL destinationChosenByUser;
@property (nonatomic, assign) BOOL operationRunning;
@end

// A plain display field that also accepts file drops (Workspace images).  The
// drop is forwarded to a block so the controller can resolve it to a restore
// source without subclassing the whole pane.
@interface DUFileDropTextField : NSTextField
@property (nonatomic, copy) void (^dropHandler)(NSArray<NSURL *> *urls);
@end

@implementation DUFileDropTextField

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    (void)info;
    return NSDragOperationCopy;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info
{
    (void)info;
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    NSPasteboard *pb = [info draggingPasteboard];
    NSArray *entries = [pb propertyListForType:NSFilenamesPboardType];
    if (entries == nil) {
        entries = [pb propertyListForType:NSURLPboardType];
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (id entry in entries) {
        NSURL *url = nil;
        if ([entry isKindOfClass:[NSString class]]) {
            url = [NSURL fileURLWithPath:entry];
        } else if ([entry isKindOfClass:[NSURL class]]) {
            url = entry;
        }
        if (url != nil && [url isFileURL]) {
            [urls addObject:url];
        }
    }
    if (urls.count > 0 && self.dropHandler != nil) {
        self.dropHandler(urls);
    }
    return urls.count > 0;
}

@end

@implementation DURestoreViewController

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

    CGFloat width = 400.0;
    // DUPaneView re-runs the layout whenever the tab view resizes us.
    DUPaneView *pane = [[DUPaneView alloc]
        initWithFrame:NSMakeRect(0, 0, width, 200)];
    pane.layoutOwner = self;
    pane.layoutSelector = @selector(relayout);
    _view = pane;
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _sourceLabel = [self label:NSLocalizedString(@"Source:", nil)];
    DUFileDropTextField *sourceField = [[DUFileDropTextField alloc] init];
    sourceField.editable = NO;
    // Let image files be dropped straight onto the Source field, mirroring
    // the "Image File..." route in the chooser.
    [sourceField
        registerForDraggedTypes:@[ NSFilenamesPboardType, NSURLPboardType ]];
    __weak typeof(self) weakSelf = self;
    sourceField.dropHandler = ^(NSArray<NSURL *> *urls) {
        [weakSelf sourceDroppedFileAtURL:urls.firstObject];
    };
    _sourceField = sourceField;
    _sourceChooseButton = [self button:NSLocalizedString(@"Choose...", nil)
                                 action:@selector(chooseSource:)];

    _destinationLabel = [self label:NSLocalizedString(@"Destination:", nil)];
    _destinationField = [[NSTextField alloc] init];
    _destinationField.editable = NO;
    _destinationChooseButton =
        [self button:NSLocalizedString(@"Choose...", nil)
              action:@selector(chooseDestination:)];

    _eraseDestinationCheck = [[NSButton alloc] initWithFrame:NSZeroRect];
    _eraseDestinationCheck.buttonType = NSSwitchButton;
    _eraseDestinationCheck.title =
        NSLocalizedString(@"Erase destination", nil);
    _eraseDestinationCheck.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [_eraseDestinationCheck sizeToFit];

    _skipChecksumCheck = [[NSButton alloc] initWithFrame:NSZeroRect];
    _skipChecksumCheck.buttonType = NSSwitchButton;
    _skipChecksumCheck.title = NSLocalizedString(@"Skip checksum", nil);
    _skipChecksumCheck.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [_skipChecksumCheck sizeToFit];

    _restoreButton = [self button:NSLocalizedString(@"Restore", nil)
                           action:@selector(restoreClicked:)];
    _restoreButton.keyEquivalent = @"\r";

    for (NSView *subview in @[ _sourceLabel, _sourceField,
                               _sourceChooseButton,
                               _destinationLabel, _destinationField,
                               _destinationChooseButton,
                               _eraseDestinationCheck,
                               _skipChecksumCheck,
                               _restoreButton ]) {
        [_view addSubview:subview];
    }

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationDidFinish:)
               name:DUOperationDidFinishNotification
             object:nil];

    [self layoutForWidth:NSWidth(_view.frame) height:NSHeight(_view.frame)];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Construction helpers

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

- (NSButton *)button:(NSString *)title action:(SEL)action
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

- (void)layoutForWidth:(CGFloat)width height:(CGFloat)height
{
    CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat bottom = METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat contentWidth = width - 2 * side;
    CGFloat rowGap = METRICS_SPACE_16;
    CGFloat chooseWidth = NSWidth(_sourceChooseButton.frame);

    // Bottom row: restore button lower-right.
    CGFloat restoreY = bottom;
    [_restoreButton setFrameOrigin:
        NSMakePoint(width - side - NSWidth(_restoreButton.frame), restoreY)];

    // Checkbox pair stacked 20px baseline-to-baseline (HIG radio/checkbox
    // line spacing); no height subtraction or the 18px frames overlap.
    CGFloat checkY = restoreY + METRICS_BUTTON_SMALL_HEIGHT + rowGap;
    [_skipChecksumCheck setFrameOrigin:NSMakePoint(side, checkY)];
    [_eraseDestinationCheck setFrameOrigin:
        NSMakePoint(side, checkY + METRICS_RADIO_BUTTON_LINE_SPACING)];

    // Destination and source rows above that; fields stretch on resize.
    CGFloat destinationY = checkY +
        2 * METRICS_RADIO_BUTTON_LINE_SPACING + rowGap;
    CGFloat fieldWidth = contentWidth - chooseWidth - METRICS_SPACE_8;
    [_destinationChooseButton setFrameOrigin:
        NSMakePoint(width - side - chooseWidth, destinationY)];
    _destinationField.frame =
        NSMakeRect(side + 90, destinationY, fieldWidth - 90,
                   METRICS_TEXT_INPUT_FIELD_HEIGHT);
    _destinationField.autoresizingMask = NSViewWidthSizable;
    [_destinationLabel setFrameOrigin:
        NSMakePoint(side,
                    destinationY + (METRICS_TEXT_INPUT_FIELD_HEIGHT -
                                    NSHeight(_destinationLabel.frame)) /
                                       2.0)];

    CGFloat sourceY = destinationY + METRICS_TEXT_INPUT_FIELD_HEIGHT +
        rowGap;
    [_sourceChooseButton setFrameOrigin:
        NSMakePoint(width - side - chooseWidth, sourceY)];
    _sourceField.frame =
        NSMakeRect(side + 90, sourceY, fieldWidth - 90,
                   METRICS_TEXT_INPUT_FIELD_HEIGHT);
    _sourceField.autoresizingMask = NSViewWidthSizable;
    [_sourceLabel setFrameOrigin:
        NSMakePoint(side,
                    sourceY + (METRICS_TEXT_INPUT_FIELD_HEIGHT -
                               NSHeight(_sourceLabel.frame)) / 2.0)];

    (void)height;
}

#pragma mark - Selection state

- (void)refreshForObject:(DUStorageObject *)object
            capabilities:(DUStorageCapabilities *)capabilities
{
    self.currentObject = object;
    // Preselect the current selection as a convenience while the user has
    // not picked a destination explicitly; both roles remain
    // user-changeable afterwards.
    if (object != nil && object.capabilities.canErase &&
        !self.destinationChosenByUser) {
        self.resolvedDestination = object;
        _destinationField.stringValue = object.displayName ?: @"";
    }
    [self updateEnabledStates:capabilities];
}

- (void)setSourceObject:(DUStorageObject *)object
{
    if (object == nil) {
        return;
    }
    self.resolvedSource = object;
    _sourceField.stringValue = object.displayName ?: @"";
    [self updateEnabledStates:nil];
}

- (void)setControlsEnabled:(BOOL)enabled
{
    self.operationRunning = !enabled;
    [self updateEnabledStates:nil];
}

- (void)updateEnabledStates:(DUStorageCapabilities *)capabilities
{
    // The sidebar-selection capabilities are irrelevant here (they used to
    // grey the button whenever a partition without canRestore was merely
    // highlighted); what matters is the chosen pair: the source must be
    // restorable and the two roles must differ by identity.
    (void)capabilities;
    BOOL hasBoth = self.resolvedSource != nil &&
        self.resolvedDestination != nil;
    BOOL distinct = hasBoth &&
        ![self.resolvedSource.identifier
             isEqualToString:self.resolvedDestination.identifier];
    BOOL restorable = self.resolvedSource == nil ||
        self.resolvedSource.capabilities.canRestore;
    _restoreButton.enabled = !self.operationRunning && hasBoth && distinct &&
        restorable;
}

- (void)relayout
{
    [self layoutForWidth:NSWidth(self.view.frame)
                  height:NSHeight(self.view.frame)];
}

#pragma mark - Choosers

// Device/image picker listing everything from the current snapshot that
// could serve as source (images, volumes) or destination (writable).
- (DUStorageObject *)pickObject:(BOOL)forDestination
{
    NSMutableArray<DUStorageObject *> *candidates = [NSMutableArray array];
    for (DUStorageObject *root in self.storageManager.currentObjects) {
        for (DUStorageObject *object in [root flattenObjects]) {
            if ([object isKindOfClass:[DUDiskImage class]] ||
                [object isKindOfClass:[DUStorageVolume class]]) {
                [candidates addObject:object];
            } else if ([object isKindOfClass:[DUStorageDevice class]]) {
                DUStorageDevice *device = (DUStorageDevice *)object;
                if (!device.optical && device.capacityBytes > 0) {
                    [candidates addObject:device];
                }
            } else if ([object isKindOfClass:[DUPartition class]]) {
                if (forDestination) {
                    [candidates addObject:object];
                }
            }
        }
    }

    NSPopUpButton *picker =
        [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 50, 360, 26)];
    for (DUStorageObject *candidate in candidates) {
        NSString *title = [NSString stringWithFormat:@"%@ (%@)",
                             candidate.displayName ?: @"",
                             candidate.backendPath ?: @""];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:nil
                                               keyEquivalent:@""];
        item.representedObject = candidate.identifier;
        [picker.menu addItem:item];
    }
    if (picker.itemArray.count == 0 && forDestination) {
        // No writable destination exists. Source mode continues so the
        // "Image File..." route stays available on bare systems.
        return nil;
    }

    // Plain modal panel: GNUstep NSAlert lacks accessory views.
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 460, 110)
                      styleMask:NSTitledWindowMask
                        backing:NSBackingStoreBuffered
                          defer:NO];
    panel.title = forDestination
        ? NSLocalizedString(@"Choose Restore Destination", nil)
        : NSLocalizedString(@"Choose Restore Source", nil);
    CGFloat panelWidth = NSWidth(panel.frame);
    NSView *content = panel.contentView;
    picker.frame =
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                   METRICS_CONTENT_BOTTOM_MARGIN +
                       METRICS_BUTTON_HEIGHT + METRICS_SPACE_16,
                   panelWidth - 2 * METRICS_CONTENT_SIDE_MARGIN, 26);
    [content addSubview:picker];
    NSButton *selectButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(panelWidth - METRICS_CONTENT_SIDE_MARGIN -
                                     100,
                                 METRICS_CONTENT_BOTTOM_MARGIN, 100,
                                 METRICS_BUTTON_HEIGHT)];
    selectButton.title = NSLocalizedString(@"Select", nil);
    selectButton.bezelStyle = NSRoundedBezelStyle;
    selectButton.keyEquivalent = @"\r";
    [content addSubview:selectButton];
    NSButton *cancelButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(400 - METRICS_CONTENT_SIDE_MARGIN - 100 -
                                     METRICS_BUTTON_HORIZ_INTERSPACE -
                                     100,
                                 METRICS_CONTENT_BOTTOM_MARGIN, 100,
                                 METRICS_BUTTON_HEIGHT)];
    cancelButton.title = NSLocalizedString(@"Cancel", nil);
    cancelButton.bezelStyle = NSRoundedBezelStyle;
    [content addSubview:cancelButton];

    // Source mode gains a direct route to arbitrary image files; the
    // destination must remain a model object with a device node.
    NSButton *imageFileButton = nil;
    if (!forDestination) {
        imageFileButton = [[NSButton alloc]
            initWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                                     METRICS_CONTENT_BOTTOM_MARGIN, 120,
                                     METRICS_BUTTON_HEIGHT)];
        [imageFileButton setTitle:NSLocalizedString(@"Image File...", nil)];
        imageFileButton.bezelStyle = NSRoundedBezelStyle;
        [imageFileButton sizeToFit];
        [content addSubview:imageFileButton];
    }

    ModalPickerContext context;
    context.picker = picker;
    context.done = NO;
    context.filePath = nil;
    objc_setAssociatedObject(selectButton, "duCtx",
                             [NSValue valueWithPointer:&context],
                             OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(cancelButton, "duCtx",
                             [NSValue valueWithPointer:&context],
                             OBJC_ASSOCIATION_RETAIN);
    if (imageFileButton != nil) {
        objc_setAssociatedObject(imageFileButton, "duCtx",
                                 [NSValue valueWithPointer:&context],
                                 OBJC_ASSOCIATION_RETAIN);
        [imageFileButton setTarget:self];
        [imageFileButton setAction:@selector(pickerImageFileClicked:)];
    }
    [selectButton setTarget:self];
    [selectButton setAction:@selector(pickerSelected:)];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(pickerCancelled:)];

    [panel center];
    [NSApp runModalForWindow:panel];
    [panel orderOut:nil];

    if (!context.done) {
        return nil;
    }
    if (context.filePath.length > 0) {
        return [self transientImageForPath:context.filePath];
    }
    NSString *identifier = picker.selectedItem.representedObject;
    return [self.storageManager objectForIdentifier:identifier];
}

// Wraps an arbitrary image file as a restore-capable source. The object is
// transient (never part of the model snapshot); the backend only needs its
// backendPath to stream bytes from.
- (DUDiskImage *)transientImageForPath:(NSString *)path
{
    NSDictionary *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                          error:NULL];
    if (attributes == nil) {
        return nil;
    }

    DUDiskImage *image =
        [[DUDiskImage alloc] initWithIdentifier:path];
    image.displayName = path.lastPathComponent;
    image.path = path;
    image.backendPath = path;
    image.sizeBytes = attributes.fileSize;
    image.readOnly = YES;

    DUStorageCapabilities *capabilities =
        [DUStorageCapabilities capabilitiesWithAll:NO];
    capabilities.canRestore = YES;
    image.capabilities = capabilities;
    return image;
}

- (void)chooseSource:(id)sender
{
    (void)sender;
    DUStorageObject *picked = [self pickObject:NO];
    if (picked == nil) {
        return;
    }
    self.resolvedSource = picked;
    _sourceField.stringValue = picked.displayName ?: @"";
    [self updateEnabledStates:nil];
}

- (void)chooseDestination:(id)sender
{
    (void)sender;
    DUStorageObject *picked = [self pickObject:YES];
    if (picked == nil) {
        return;
    }
    self.resolvedDestination = picked;
    self.destinationChosenByUser = YES;
    _destinationField.stringValue = picked.displayName ?: @"";
    [self updateEnabledStates:nil];
}

// Dropped file onto the Source field: wrap it as a transient restore-capable
// image, exactly like the chooser's "Image File..." route.
- (void)sourceDroppedFileAtURL:(NSURL *)url
{
    if (url == nil) {
        return;
    }
    DUDiskImage *image = [self transientImageForPath:[url path]];
    if (image == nil) {
        return;
    }
    [self setSourceObject:image];
}

// Shared state for the modal picker panel buttons.
typedef struct {
    NSPopUpButton *picker;
    BOOL done;
    // Set by the "Image File..." button: a file path outside the model.
    NSString *filePath;
} ModalPickerContext;

- (void)pickerSelected:(id)sender
{
    (void)sender;
    NSValue *boxed = objc_getAssociatedObject(sender, "duCtx");
    if (boxed != nil) {
        ModalPickerContext *context = (ModalPickerContext *)boxed.pointerValue;
        context->done = YES;
    }
    [NSApp stopModal];
}

- (void)pickerCancelled:(id)sender
{
    (void)sender;
    NSValue *boxed = objc_getAssociatedObject(sender, "duCtx");
    if (boxed != nil) {
        ModalPickerContext *context = (ModalPickerContext *)boxed.pointerValue;
        context->done = NO;
    }
    [NSApp stopModal];
}

// Source mode only: pick an arbitrary image file from disk instead of an
// object from the model snapshot. The path rides out of the modal session
// in the context; pickObject wraps it in a transient DUDiskImage.
- (void)pickerImageFileClicked:(id)sender
{
    (void)sender;
    NSValue *boxed = objc_getAssociatedObject(sender, "duCtx");
    if (boxed == nil) {
        return;
    }
    ModalPickerContext *context = (ModalPickerContext *)boxed.pointerValue;

    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = NO;
    openPanel.allowsMultipleSelection = NO;
    // No type filter: image files come with every extension there is
    // (.img, .iso, .dmg, .gz, ...) and rejecting one would be wrong.
    openPanel.directoryURL =
        [NSURL fileURLWithPath:[@"~/Documents"
            stringByExpandingTildeInPath]];
    if ([openPanel runModal] != NSOKButton) {
        return;
    }
    context->filePath = openPanel.URL.path;
    context->done = YES;
    [NSApp stopModal];
}

#pragma mark - Action

- (void)restoreClicked:(id)sender
{
    (void)sender;
    DUStorageObject *source = self.resolvedSource;
    DUStorageObject *destination = self.resolvedDestination;
    if (source == nil || destination == nil || self.operationRunning) {
        return;
    }

    if ([[NSUserDefaults standardUserDefaults]
            boolForKey:kDefaultsConfirmDestructive]) {
        NSString *message = [NSString stringWithFormat:
            NSLocalizedString(
                @"Restoring will overwrite all data on \"%@\". Continue?",
                nil),
            destination.displayName ?: @""];
        NSInteger choice = NSRunAlertPanel(
            NSLocalizedString(@"Restore", nil),
            message,
            NSLocalizedString(@"Cancel", nil),
            NSLocalizedString(@"Restore", nil),
            nil);
        if (choice != NSAlertAlternateReturn) {
            return;
        }
    }

    NSDictionary *options = @{
        @"eraseDestination" :
            @(_eraseDestinationCheck.state == NSOnState),
        @"skipChecksum" : @(_skipChecksumCheck.state == NSOnState),
    };

    NSError *error = nil;
    [self.logView clear];
    [self.logView appendLine:[NSString stringWithFormat:
        NSLocalizedString(@"Restoring %@ to %@...", nil),
        source.displayName ?: @"",
        destination.displayName ?: @""]];
    self.operationRunning = YES;
    [self updateEnabledStates:nil];

    id<DUStorageBackend> backend = self.storageManager.backend;
    DURestoreOperation *operation =
        [[DURestoreOperation alloc] initWithBackend:backend
                                             source:source
                                        destination:destination
                                            options:options];
    if (![self.storageManager.operationManager startOperation:operation
                                                        error:&error]) {
        self.operationRunning = NO;
        [self updateEnabledStates:nil];
        [self.logView appendLine:error.localizedDescription ?: @""];
    }
}

- (void)operationDidFinish:(NSNotification *)note
{
    DUOperation *operation = note.userInfo[kDUUserInfoOperationKey];
    if (![operation isKindOfClass:[DURestoreOperation class]]) {
        return;
    }
    DURestoreOperation *restoreOperation =
        (DURestoreOperation *)operation;
    if (restoreOperation.source == self.resolvedSource) {
        [self operationFinished:note.userInfo[kDUUserInfoErrorKey]];
    }
}

- (void)operationFinished:(NSError *)error
{
    __strong typeof(self) strongSelf = self;
    if (strongSelf == nil) {
        return;
    }
    strongSelf.operationRunning = NO;
    [strongSelf updateEnabledStates:nil];
    if (error == nil) {
        [strongSelf.logView appendLine:NSLocalizedString(
                                            @"Restore completed successfully.", nil)];
    } else {
        [strongSelf.logView appendLine:NSLocalizedString(
                                            @"Restore failed.", nil)];
    }
}

@end
