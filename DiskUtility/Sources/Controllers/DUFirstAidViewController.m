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

    CGFloat width = 400.0;
    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 260)];
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
                    rowY + METRICS_BUTTON_HEIGHT +
                        METRICS_BUTTON_VERT_INTERSPACE)];

    CGFloat repairX = width - side -
        NSWidth(_repairDiskButton.frame);
    [_repairDiskButton setFrameOrigin:NSMakePoint(repairX, rowY + METRICS_BUTTON_HEIGHT + METRICS_BUTTON_VERT_INTERSPACE)];
    CGFloat verifyX = repairX - NSWidth(_verifyDiskButton.frame) -
        METRICS_BUTTON_HORIZ_INTERSPACE;
    [_verifyDiskButton setFrameOrigin:NSMakePoint(verifyX, rowY + METRICS_BUTTON_HEIGHT + METRICS_BUTTON_VERT_INTERSPACE)];

    // Log fills the middle; hidden entirely when details are off.
    BOOL showDetails = self.showDetailsCheck.state == NSOnState;
    CGFloat logBottom =
        rowY + METRICS_BUTTON_HEIGHT + METRICS_BUTTON_VERT_INTERSPACE +
        METRICS_SPACE_16;
    CGFloat logTop = height - METRICS_CONTENT_TOP_MARGIN;
    CGFloat availableHeight = MAX(40.0, logTop - logBottom);
    if (!showDetails) {
        availableHeight = 0.0;
        _logView.scrollView.hidden = YES;
    } else {
        _logView.scrollView.hidden = NO;
    }
    _logView.scrollView.frame =
        NSMakeRect(x, logBottom, contentWidth, availableHeight);

    // Instructions pinned to the top of the pane (SPEC section 10); the
    // details row and buttons stay anchored at the bottom.
    _instructions.frame = NSMakeRect(
        x,
        height - METRICS_CONTENT_TOP_MARGIN - NSHeight(_instructions.frame),
        contentWidth,
        NSHeight(_instructions.frame));

    // Details row directly above the log area.
    CGFloat detailsY =
        showDetails
            ? logBottom + availableHeight + METRICS_SPACE_8
            : logBottom + METRICS_SPACE_8;
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
    _verifyPermissionsButton.enabled =
        hasObject && !busy && caps.canRepairPermissions;
    _repairPermissionsButton.enabled = [_verifyPermissionsButton isEnabled];
    _clearHistoryButton.enabled = !busy;
}

- (void)relayout
{
    [self layoutViewsForWidth:NSWidth(self.view.frame)
                       height:NSHeight(self.view.frame)];
}

@end
