/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUFirstAidViewController.h"

#import "AppearanceMetrics.h"
#import "DUErrors.h"
#import "DUOperation.h"
#import "DUOperationLogView.h"
#import "DUPaneView.h"
#import "DUStorageCapabilities.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"

// Defaults keys per ARCHITECTURE.md section 67.
static NSString * const kDefaultsShowDetails = @"DUShowDetails";
static NSString * const kDefaultsConfirmDestructive =
    @"DUConfirmDestructiveOperations";

@interface DUFirstAidViewController ()
@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong) DUOperationLogView *logView;
@property (nonatomic, strong, readwrite) NSView *view;

@property (nonatomic, strong) NSTextField *instructions;
@property (nonatomic, strong) NSButton *showDetailsCheck;
@property (nonatomic, strong) NSButton *clearHistoryButton;
@property (nonatomic, strong) NSButton *verifyPermissionsButton;
@property (nonatomic, strong) NSButton *repairPermissionsButton;
@property (nonatomic, strong) NSButton *verifyDiskButton;
@property (nonatomic, strong) NSButton *repairDiskButton;

@property (nonatomic, weak) DUStorageObject *currentObject;
@property (nonatomic, strong) DUStorageCapabilities *currentCapabilities;
@property (nonatomic, assign) BOOL operationRunning;
@end

@implementation DUFirstAidViewController

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

    // DUPaneView re-runs the layout whenever the tab view resizes us.
    CGFloat width = 400.0;
    DUPaneView *pane = [[DUPaneView alloc]
        initWithFrame:NSMakeRect(0, 0, width, 260)];
    pane.layoutOwner = self;
    pane.layoutSelector = @selector(relayout);
    _view = pane;
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Built manually: GNUstep NSTextField lacks the modern wrapping-label
    // convenience constructor.
    _instructions = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _instructions.editable = NO;
    _instructions.bezeled = NO;
    _instructions.drawsBackground = NO;
    [(NSCell *)_instructions.cell setWraps:YES];
    _instructions.stringValue = NSLocalizedString(
        @"If you are having problems with the selected volume, you can "
        @"verify its structure and attempt to repair errors. "
        @"Permission operations apply to system volumes only.",
        nil);
    _instructions.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [(NSCell *)_instructions.cell setWraps:YES];
    // Reserve two lines up front: sizeToFit measures a single line for
    // wrapping cells, truncating the second sentence.
    {
        CGFloat lineHeight = METRICS_FONT_SYSTEM_REGULAR_11.defaultLineHeightForFont + 2.0;
        _instructions.frame =
            NSMakeRect(0, 0, 352, 2 * lineHeight);
    }
    [_instructions sizeToFit];

    _showDetailsCheck = [[NSButton alloc] initWithFrame:NSZeroRect];
    _showDetailsCheck.buttonType = NSSwitchButton;
    _showDetailsCheck.title = NSLocalizedString(@"Show details", nil);
    _showDetailsCheck.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [_showDetailsCheck setTarget:self];
    [_showDetailsCheck setAction:@selector(toggleShowDetails:)];

    _clearHistoryButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _clearHistoryButton.title = NSLocalizedString(@"Clear History", nil);
    _clearHistoryButton.bezelStyle = NSRoundedBezelStyle;
    _clearHistoryButton.font = METRICS_FONT_SYSTEM_REGULAR_11;
    [_clearHistoryButton setTarget:self];
    [_clearHistoryButton setAction:@selector(clearHistory:)];
    [_clearHistoryButton sizeToFit];
    {
        NSRect frame = _clearHistoryButton.frame;
        frame.size.height = METRICS_BUTTON_SMALL_HEIGHT;
        _clearHistoryButton.frame = frame;
    }

    _verifyPermissionsButton =
        [self buttonWithTitle:NSLocalizedString(@"Verify Permissions", nil)
                       action:@selector(verifyPermissions:)];
    _repairPermissionsButton =
        [self buttonWithTitle:NSLocalizedString(@"Repair Permissions", nil)
                       action:@selector(repairPermissions:)];
    _verifyDiskButton =
        [self buttonWithTitle:NSLocalizedString(@"Verify Disk", nil)
                       action:@selector(verifyDisk:)];
    _repairDiskButton =
        [self buttonWithTitle:NSLocalizedString(@"Repair Disk", nil)
                       action:@selector(repairDisk:)];

    for (NSView *subview in @[ _instructions,
                               _showDetailsCheck,
                               _clearHistoryButton,
                               _logView.scrollView,
                               _verifyPermissionsButton,
                               _repairPermissionsButton,
                               _verifyDiskButton,
                               _repairDiskButton ]) {
        [_view addSubview:subview];
    }

    _showDetailsCheck.state =
        [[NSUserDefaults standardUserDefaults]
            boolForKey:kDefaultsShowDetails]
            ? NSOnState
            : NSOffState;
    [self layoutViewsForWidth:NSWidth(_view.frame)
                       height:NSHeight(_view.frame)];
    return self;
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

// Manual layout per SPEC section 9; anchored bottom-up so a taller window
// grows the log view (SPEC section 36 resize behavior).
- (void)layoutViewsForWidth:(CGFloat)width height:(CGFloat)height
{
    CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat bottom = METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat x = side;
    CGFloat contentWidth = width - 2 * side;

    // Bottom rows: permission group on the left, filesystem group right.
    CGFloat rowY = bottom;
    [_repairPermissionsButton setFrameOrigin:NSMakePoint(x, rowY)];
    [_verifyPermissionsButton setFrameOrigin:
        NSMakePoint(x,
                    rowY + METRICS_BUTTON_SMALL_HEIGHT +
                        METRICS_BUTTON_VERT_INTERSPACE)];

    CGFloat repairX = width - side -
        NSWidth(_repairDiskButton.frame);
    [_repairDiskButton setFrameOrigin:NSMakePoint(repairX, rowY + METRICS_BUTTON_SMALL_HEIGHT + METRICS_BUTTON_VERT_INTERSPACE)];
    CGFloat verifyX = repairX - NSWidth(_verifyDiskButton.frame) -
        METRICS_BUTTON_HORIZ_INTERSPACE;
    // Same row as Repair Disk, so the same (small) button height applies.
    [_verifyDiskButton setFrameOrigin:
        NSMakePoint(verifyX,
                    rowY + METRICS_BUTTON_SMALL_HEIGHT +
                        METRICS_BUTTON_VERT_INTERSPACE)];

    // Log fills the middle; hidden entirely when details are off or when
    // the pane is too short to hold instructions + details row + log
    // without overlap (ARCHITECTURE.md section 31: degrade, never collide).
    BOOL showDetails = self.showDetailsCheck.state == NSOnState;
    // The bottom cluster stacks TWO button rows (permissions pair left,
    // disk pair right): 17 + 12 + 17 before any breathing room.
    CGFloat logBottom =
        rowY + 2 * METRICS_BUTTON_SMALL_HEIGHT +
        METRICS_BUTTON_VERT_INTERSPACE + METRICS_SPACE_16;

    // Instructions pinned to the top of the pane (SPEC section 10); the
    // details row and buttons stay anchored at the bottom.
    CGFloat instructionsHeight = NSHeight(_instructions.frame);
    CGFloat instructionsY = height - METRICS_CONTENT_TOP_MARGIN -
        instructionsHeight;
    _instructions.frame = NSMakeRect(
        x, instructionsY, contentWidth, instructionsHeight);

    // Room between the button cluster and the instruction block must hold
    // an 8px gap, the 18px details row and an 8px gap before any log.
    CGFloat availableSpace = instructionsY - METRICS_SPACE_8 - logBottom;
    BOOL logVisible = showDetails && availableSpace >=
        (METRICS_RADIO_BUTTON_LINE_SPACING + 2 * METRICS_SPACE_8 + 24);
    CGFloat availableHeight = 0.0;
    if (logVisible) {
        availableHeight = availableSpace -
            (METRICS_RADIO_BUTTON_LINE_SPACING + 2 * METRICS_SPACE_8);
        _logView.scrollView.hidden = NO;
    } else {
        _logView.scrollView.hidden = YES;
    }
    _logView.scrollView.frame =
        NSMakeRect(x, logBottom, contentWidth, availableHeight);

    // Details row directly above the log area (or just above the buttons
    // when the log is hidden).
    CGFloat detailsY =
        logVisible
            ? logBottom + availableHeight + METRICS_SPACE_8
            : MIN(logBottom + METRICS_SPACE_8,
                  instructionsY - METRICS_RADIO_BUTTON_LINE_SPACING);
    [_showDetailsCheck sizeToFit];
    [_showDetailsCheck setFrameOrigin:NSMakePoint(x, detailsY)];
    [_clearHistoryButton setFrameOrigin:
        NSMakePoint(width - side - NSWidth(_clearHistoryButton.frame),
                    detailsY)];
}

#pragma mark - Actions

- (void)toggleShowDetails:(id)sender
{
    (void)sender;
    BOOL show = self.showDetailsCheck.state == NSOnState;
    [[NSUserDefaults standardUserDefaults]
        setBool:show forKey:kDefaultsShowDetails];
    [self relayout];
}

- (void)clearHistory:(id)sender
{
    (void)sender;
    [self.logView clear];
}

- (void)verifyPermissions:(id)sender
{
    (void)sender;
    // Unix permission semantics have no equivalent of the classic
    // permissions check; buttons stay visible but disabled via capability.
}

- (void)repairPermissions:(id)sender
{
    (void)sender;
    DUStorageObject *object = self.currentObject;
    if (object == nil || self.operationRunning) {
        return;
    }
    id<DUStorageBackend> backend = self.storageManager.backend;
    if (![backend respondsToSelector:
              @selector(repairHomePermissionsWithProgress:completion:)]) {
        [self.logView appendLine:NSLocalizedString(
            @"Repair Permissions is not available on this platform.", nil)];
        return;
    }
    __weak typeof(self) weakSelf = self;
    void (^progressBlock)(double, NSString *) =
        ^(double progress, NSString *message) {
            (void)progress;
            [weakSelf.logView appendLine:message];
        };
    void (^completionBlock)(NSError *) =
        ^(NSError *completionError) {
            [weakSelf operationFinished:completionError
                             failedTitle:NSLocalizedString(
                                 @"Repair Permissions failed.", nil)];
        };
    [self.logView appendLine:NSLocalizedString(
        @"Repairing home directory permissions...", nil)];
    self.operationRunning = YES;
    [self updateEnabledStates];
    [backend repairHomePermissionsWithProgress:progressBlock
                                    completion:completionBlock];
}

- (void)verifyDisk:(id)sender
{
    (void)sender;
    [self runStarter:@selector(verifyObject:onProgress:onCompletion:error:)
             started:NSLocalizedString(@"Verifying volume...", nil)
              failed:NSLocalizedString(@"Verification completed with errors.", nil)];
}

- (void)repairDisk:(id)sender
{
    (void)sender;
    // Destructive confirmation with the safer action as the default button
    // (SPEC section 32).
    if ([[NSUserDefaults standardUserDefaults]
            boolForKey:kDefaultsConfirmDestructive]) {
        NSInteger choice = NSRunAlertPanel(
            NSLocalizedString(@"Repair Disk", nil),
            NSLocalizedString(
                @"Repairing may change the contents of the selected "
                @"volume. Continue?",
                nil),
            NSLocalizedString(@"Cancel", nil),
            NSLocalizedString(@"Repair", nil),
            nil);
        if (choice != NSAlertAlternateReturn) {
            return;
        }
    }
    [self runStarter:@selector(repairObject:onProgress:onCompletion:error:)
             started:NSLocalizedString(@"Repairing volume...", nil)
              failed:NSLocalizedString(@"Repair failed.", nil)];
}

- (void)runStarter:(SEL)starter
           started:(NSString *)startedMessage
            failed:(NSString *)failedTitle
{
    DUStorageObject *object = self.currentObject;
    if (object == nil || self.operationRunning) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^progressBlock)(double, NSString *) =
        ^(double progress, NSString *message) {
            (void)progress;
            [weakSelf.logView appendLine:message];
        };
    void (^completionBlock)(NSError *) =
        ^(NSError *completionError) {
            [weakSelf operationFinished:completionError
                            failedTitle:failedTitle];
        };

    NSError *error = nil;
    DUOperation *operation = nil;
    // The operation log is one shared view across all panes, so clear it
    // before each run; otherwise a previous (e.g. erase) line would linger
    // and read as if this nondestructive operation had produced it.
    [self.logView clear];
    [self.logView appendLine:startedMessage];
    self.operationRunning = YES;
    [self updateEnabledStates];

    if (starter == @selector(verifyObject:onProgress:onCompletion:error:)) {
        operation = [self.storageManager verifyObject:object
                                           onProgress:progressBlock
                                         onCompletion:completionBlock
                                                error:&error];
    } else {
        operation = [self.storageManager repairObject:object
                                           onProgress:progressBlock
                                         onCompletion:completionBlock
                                                error:&error];
    }

    if (operation == nil) {
        self.operationRunning = NO;
        [self updateEnabledStates];
        [self.logView appendLine:
                          error.localizedDescription ?: NSLocalizedString(
                              @"The operation could not be started.", nil)];
    }
}

- (void)operationFinished:(NSError *)error
               failedTitle:(NSString *)unusedFailedTitle
{
    (void)unusedFailedTitle; // wording comes from the shared completion text
    __strong typeof(self) strongSelf = self;
    if (strongSelf == nil) {
        return;
    }
    strongSelf.operationRunning = NO;
    [strongSelf updateEnabledStates];
    if (error == nil) {
        [strongSelf.logView appendLine:NSLocalizedString(
                                            @"Operation completed successfully.", nil)];
    } else if (error.code == DUErrorCancelled) {
        [strongSelf.logView appendLine:
                              NSLocalizedString(@"Operation cancelled.", nil)];
    } else {
        [strongSelf.logView appendLine:
                              NSLocalizedString(@"Operation failed.", nil)];
        [strongSelf.logView appendLine:NSLocalizedString(
                                            @"See the operation details for more information.", nil)];
    }
}

#pragma mark - State

- (void)setControlsEnabled:(BOOL)enabled
{
    self.operationRunning = !enabled;
    [self updateEnabledStates];
}

- (void)refreshForObject:(DUStorageObject *)object
            capabilities:(DUStorageCapabilities *)capabilities
{
    self.currentObject = object;
    self.currentCapabilities = capabilities;
    [self updateEnabledStates];
}

- (void)updateEnabledStates
{
    BOOL busy = self.operationRunning;
    DUStorageCapabilities *caps = self.currentCapabilities;
    BOOL hasObject = self.currentObject != nil;

    _verifyDiskButton.enabled = hasObject && !busy && caps.canVerify;
    _repairDiskButton.enabled = hasObject && !busy && caps.canRepair;
    // No Unix equivalent of the classic permissions check exists, so the
    // Verify Permissions button stays disabled on every platform.
    _verifyPermissionsButton.enabled = NO;
    _repairPermissionsButton.enabled =
        hasObject && !busy && caps.canRepairPermissions;
    _clearHistoryButton.enabled = !busy;
}

- (void)relayout
{
    [self layoutViewsForWidth:NSWidth(self.view.frame)
                       height:NSHeight(self.view.frame)];
}

@end
