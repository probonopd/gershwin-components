/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUMainWindowController.h"

#import <objc/runtime.h>

#import "AppearanceMetrics.h"
#import "DUDiskMapView.h"
#import "DUErrors.h"
#import "DUDeviceBrowserController.h"
#import "DUIcons.h"
#import "DUInformationController.h"
#import "DUOperationController.h"
#import "DUPreferencesController.h"
#import "DUNewImageController.h"
#import "DUNotifications.h"
#import "DUOperation.h"
#import "DUOperationLogView.h"
#import "DUOperationManager.h"
#import "DUParsing.h"
#import "DUStorageCapabilities.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"

// Window geometry per SPEC sections 2 and 37.
static const CGFloat kDefaultWindowWidth = 780.0;
static const CGFloat kDefaultWindowHeight = 535.0;
static const CGFloat kMinimumWindowWidth = 650.0;
static const CGFloat kMinimumWindowHeight = 450.0;
static const CGFloat kBrowserWidth = 190.0;
static const CGFloat kToolbarHeight = 44.0;
static const CGFloat kInfoPanelHeight = 120.0;
static const CGFloat kSeparatorThickness = 1.0;
// Operation status strip above the info footer: visible while any storage
// operation runs, so long work never needs a modal dialog (ARCHITECTURE.md
// section 31).
static const CGFloat kOperationStripHeight = 32.0;
// One-line result readout along the very bottom edge ("Image created
// successfully.", tool errors, ...) that outlives the progress strip.
static const CGFloat kStatusLineHeight = 20.0;

// Defaults key per ARCHITECTURE.md section 67/68.
static NSString * const kDefaultsWindowFrame = @"DUWindowFrame";

@interface DUMainWindowController ()
    <DUDeviceBrowserDelegate>
@property (nonatomic, strong) DUStorageManager *storageManager;
@property (nonatomic, strong) DUDeviceBrowserController *browserController;
@property (nonatomic, strong) DUOperationController *operationController;
@property (nonatomic, strong) DUInformationController *informationController;

@property (nonatomic, strong) NSArray<NSButton *> *toolbarButtons;
@property (nonatomic, strong) NSView *toolbarArea;

// Live operation reporting (strip contents).
@property (nonatomic, strong) NSView *operationStrip;
@property (nonatomic, strong) NSProgressIndicator *operationBar;
@property (nonatomic, strong) NSTextField *operationStatus;
@property (nonatomic, strong) NSButton *stopButton;
// Bottom-edge one-liner carrying the outcome of the last operation.
@property (nonatomic, strong) NSTextField *completionLabel;
// Keeps the finished bar on screen for kStripGraceSeconds.
@property (nonatomic, strong) NSTimer *stripHideTimer;
// Per-operation last appended log message; keeps identical consecutive
// tool lines from spamming the text view.
@property (nonatomic, strong)
    NSMutableDictionary<NSString *, NSString *> *lastLoggedMessageByOperation;

// Current selection mirrored here so toolbar handlers can act on it.
@property (nonatomic, weak) DUStorageObject *selectedObject;
/* Strong identifier of the selection: survives catalog rescans that
 * replace the (weakly held) selected object. */
@property (nonatomic, strong) DUNewImageController *imagePanelController;
@property (nonatomic, strong) NSWindow *infoWindow;
@property (nonatomic, strong) DUInformationController *infoWindowController;
@end

// Opaque window background: the plain NSView content view draws nothing,
// so any region whose view gets hidden or removed (operation strip folding
// away, tab swaps) keeps stale pixels forever - text doubled over text.
// Drawing the background here lets every damage rect heal on its own.
@interface DUContentView : NSView
@end

@implementation DUContentView
- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(self.bounds);
}
@end

@implementation DUMainWindowController

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
{
    NSParameterAssert(manager != nil);
    NSRect frame = [self restoredFrame];
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:NSTitledWindowMask
                                        | NSClosableWindowMask
                                        | NSMiniaturizableWindowMask
                                        | NSResizableWindowMask
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    window.title = NSLocalizedString(@"Disk Utility", nil);
    window.minSize = NSMakeSize(kMinimumWindowWidth, kMinimumWindowHeight);
    self = [super initWithWindow:window];
    if (self == nil) {
        return nil;
    }
    _storageManager = manager;
    _lastLoggedMessageByOperation = [NSMutableDictionary dictionary];

    _operationController =
        [[DUOperationController alloc] initWithStorageManager:manager];

    _browserController =
        [[DUDeviceBrowserController alloc] initWithStorageManager:manager];
    _browserController.delegate = self;

    /* Created eagerly so the outline selection can always be mirrored to
     * the New Image panel's read-only source field. */
    _imagePanelController =
        [[DUNewImageController alloc] initWithStorageManager:manager
                                                     logView:_operationController.logView];

    _informationController = [[DUInformationController alloc] init];

    [self buildLayoutInWindow:window];
    [self buildToolbarButtons];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(topologyDidChange:)
               name:DUStorageTopologyDidChangeNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationStateDidChange:)
               name:DUOperationDidStartNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationDidUpdate:)
               name:DUOperationDidUpdateNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationStateDidChange:)
               name:DUOperationDidFinishNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationDidFail:)
               name:DUOperationDidFailNotification
             object:nil];
    return self;
}

- (void)dealloc
{
    [self.stripHideTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Layout

- (void)buildLayoutInWindow:(NSWindow *)window
{
    NSView *oldContent = window.contentView;
    DUContentView *content = [[DUContentView alloc]
        initWithFrame:[oldContent frame]];
    content.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = content;
    CGFloat height = NSHeight(content.frame);

    // Toolbar strip pinned under the titlebar; every pane sits below it.
    NSView *toolbarArea =
        [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                 height - kToolbarHeight,
                                                 NSWidth(content.frame),
                                                 kToolbarHeight)];
    // Flexible bottom margin keeps the strip glued to the window top.
    toolbarArea.autoresizingMask =
        NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:toolbarArea];
    self.toolbarArea = toolbarArea;

    CGFloat middleBottom = kStatusLineHeight + kInfoPanelHeight +
                           kSeparatorThickness + kOperationStripHeight;
    CGFloat middleHeight =
        height - kToolbarHeight - kSeparatorThickness - middleBottom;

    // Browser column: fixed width per SPEC section 36.
    NSView *browserPane = _browserController.containerView;
    browserPane.frame = NSMakeRect(0, middleBottom, kBrowserWidth, middleHeight);
    browserPane.autoresizingMask = NSViewHeightSizable;

    // Operation area takes all remaining width and height.
    NSView *operationArea =
        [[NSView alloc] initWithFrame:NSMakeRect(
                           kBrowserWidth + kSeparatorThickness,
                           middleBottom,
                           NSWidth(content.frame) - kBrowserWidth -
                               kSeparatorThickness,
                           middleHeight)];
    operationArea.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    [self embedSubview:_operationController.tabView inContainer:operationArea];

    // Operation status strip: progress bar, live tool status and a Stop
    // control. Hidden while idle; its reserved space keeps the layout
    // stable across show/hide.
    CGFloat stripY = kStatusLineHeight + kInfoPanelHeight + kSeparatorThickness;
    NSView *strip =
        [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                 stripY,
                                                 NSWidth(content.frame),
                                                 kOperationStripHeight)];
    // Bottom-anchored on purpose (MaxYMargin = flexible top margin in the
    // y-up system): strip, info footer and status line form a fixed stack
    // above the window bottom. A MinYMargin here would let resize deltas
    // push them into the tab area.
    strip.autoresizingMask =
        NSViewWidthSizable | NSViewMaxYMargin;

    NSProgressIndicator *bar = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                                 (kOperationStripHeight - 16.0) / 2.0,
                                 220.0, 16.0)];
    bar.minValue = 0.0;
    bar.maxValue = 100.0;
    bar.doubleValue = 0.0;
    [bar setIndeterminate:NO];

    NSTextField *status = [[NSTextField alloc]
        initWithFrame:NSMakeRect(
                           METRICS_CONTENT_SIDE_MARGIN + 232.0,
                           (kOperationStripHeight -
                            METRICS_TEXT_INPUT_FIELD_HEIGHT) / 2.0,
                           NSWidth(content.frame) - 232.0 - 90.0 -
                               3 * METRICS_CONTENT_SIDE_MARGIN,
                           METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    status.editable = NO;
    status.bezeled = NO;
    status.drawsBackground = NO;
    status.font = METRICS_FONT_SYSTEM_REGULAR_11;
    status.stringValue = @"";

    NSButton *stopButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(NSWidth(content.frame) -
                                     METRICS_CONTENT_SIDE_MARGIN - 80.0,
                                 (kOperationStripHeight -
                                  METRICS_BUTTON_SMALL_HEIGHT) / 2.0,
                                 80.0,
                                 METRICS_BUTTON_SMALL_HEIGHT)];
    stopButton.title = NSLocalizedString(@"Stop", nil);
    stopButton.bezelStyle = NSRoundedBezelStyle;
    stopButton.font = METRICS_FONT_SYSTEM_REGULAR_11;
    stopButton.autoresizingMask = NSViewMinXMargin;
    [stopButton setTarget:self];
    [stopButton setAction:@selector(stopClicked:)];
    [stopButton sizeToFit];
    stopButton.frame = NSMakeRect(
        NSWidth(content.frame) - METRICS_CONTENT_SIDE_MARGIN -
            NSWidth(stopButton.frame),
        (kOperationStripHeight - METRICS_BUTTON_SMALL_HEIGHT) / 2.0,
        NSWidth(stopButton.frame), METRICS_BUTTON_SMALL_HEIGHT);

    [strip addSubview:bar];
    [strip addSubview:status];
    [strip addSubview:stopButton];
    strip.hidden = YES;
    self.operationStrip = strip;
    self.operationBar = bar;
    self.operationStatus = status;
    self.stopButton = stopButton;

    // Information footer spans the full width above the bottom status line.
    NSView *infoArea =
        [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                 kStatusLineHeight,
                                                 NSWidth(content.frame),
                                                 kInfoPanelHeight)];
    infoArea.autoresizingMask =
        NSViewWidthSizable | NSViewMaxYMargin;
    [self embedSubview:_informationController.view inContainer:infoArea];

    // Bottom-edge result line: the outcome of the last operation lives here
    // after the progress strip folds away. 17px inside the 20px band so it
    // can never touch either separator.
    NSTextField *completionLabel = [[NSTextField alloc]
        initWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                                 (kStatusLineHeight -
                                  METRICS_BUTTON_SMALL_HEIGHT) / 2.0,
                                 NSWidth(content.frame) -
                                     2 * METRICS_CONTENT_SIDE_MARGIN,
                                 METRICS_BUTTON_SMALL_HEIGHT)];
    completionLabel.editable = NO;
    completionLabel.bezeled = NO;
    completionLabel.drawsBackground = NO;
    completionLabel.font = METRICS_FONT_SYSTEM_REGULAR_11;
    completionLabel.stringValue = @"";
    completionLabel.autoresizingMask =
        NSViewWidthSizable | NSViewMaxYMargin;
    self.completionLabel = completionLabel;

    // Thin separators between regions (SPEC sections 5 and 22).
    NSBox *verticalSeparator =
        [[NSBox alloc] initWithFrame:NSMakeRect(kBrowserWidth,
                                                middleBottom,
                                                kSeparatorThickness,
                                                middleHeight)];
    verticalSeparator.boxType = NSBoxSeparator;
    verticalSeparator.autoresizingMask = NSViewHeightSizable;

    NSBox *horizontalSeparator =
        [[NSBox alloc] initWithFrame:NSMakeRect(0,
                                                kStatusLineHeight +
                                                    kInfoPanelHeight,
                                                NSWidth(content.frame),
                                                kSeparatorThickness)];
    horizontalSeparator.boxType = NSBoxSeparator;
    // Sits directly on top of the info footer: bottom-anchored with it.
    horizontalSeparator.autoresizingMask =
        NSViewWidthSizable | NSViewMaxYMargin;

    NSBox *toolbarSeparator =
        [[NSBox alloc] initWithFrame:NSMakeRect(
                          0,
                          height - kToolbarHeight - kSeparatorThickness,
                          NSWidth(content.frame),
                          kSeparatorThickness)];
    toolbarSeparator.boxType = NSBoxSeparator;
    toolbarSeparator.autoresizingMask =
        NSViewWidthSizable | NSViewMinYMargin;

    [content addSubview:browserPane];
    [content addSubview:operationArea];
    [content addSubview:infoArea];
    [content addSubview:self.completionLabel];
    [content addSubview:self.operationStrip];
    [content addSubview:verticalSeparator];
    [content addSubview:horizontalSeparator];
    [content addSubview:toolbarSeparator];
}

- (void)embedSubview:(NSView *)subview inContainer:(NSView *)container
{
    subview.frame = container.bounds;
    subview.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:subview];
}

#pragma mark - Toolbar

- (NSImage *)toolbarIcon:(NSString *)name
{
    return [DUIcons iconNamed:name];
}

- (void)buildToolbarButtons
{
    NSArray<NSDictionary *> *items = @[
        @{ @"title" : NSLocalizedString(@"Verify", nil), @"icon" : @"verify", @"token" : @"verify" },
        @{ @"title" : NSLocalizedString(@"Info", nil), @"icon" : @"info", @"token" : @"info" },
        @{ @"title" : NSLocalizedString(@"Burn", nil), @"icon" : @"burn", @"token" : @"burn" },
        @{ @"title" : NSLocalizedString(@"Mount", nil), @"icon" : @"mount", @"token" : @"mount" },
        @{ @"title" : NSLocalizedString(@"Eject", nil), @"icon" : @"eject", @"token" : @"eject" },
        @{ @"title" : NSLocalizedString(@"Journaling", nil), @"icon" : @"journal", @"token" : @"journaling" },
        @{ @"title" : NSLocalizedString(@"New Image", nil), @"icon" : @"newimage", @"token" : @"newimage" },
        @{ @"title" : NSLocalizedString(@"Convert", nil), @"icon" : @"convert", @"token" : @"convert" },
        @{ @"title" : NSLocalizedString(@"Resize Image", nil), @"icon" : @"resize", @"token" : @"resize" },
    ];

    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    // Icon-over-label bevel buttons inside the top strip (SPEC section 4);
    // 8px spacing per the AppearanceMetrics toolbar guidance.
    CGFloat x = METRICS_CONTENT_SIDE_MARGIN;
    // Symmetric 4px vertical insets inside the 44px strip; the metrics
    // guidance allows any even spacing step.
    const CGFloat toolbarInset = 4.0;
    CGFloat buttonHeight = kToolbarHeight - 2 * toolbarInset;
    for (NSDictionary *item in items) {
        NSButton *button = [[NSButton alloc]
            initWithFrame:NSMakeRect(x, toolbarInset, 64, buttonHeight)];
        button.title = item[@"title"];
        button.image = [self toolbarIcon:item[@"icon"]];
        button.imagePosition = NSImageAbove;
        button.bezelStyle = NSShadowlessSquareBezelStyle;
        [button setBordered:NO];
        button.font = METRICS_FONT_SYSTEM_REGULAR_11;
        objc_setAssociatedObject(button, "duToken", item[@"token"],
                                 OBJC_ASSOCIATION_COPY);
        button.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        [button setTarget:self];
        [button setAction:@selector(toolbarClicked:)];
        [self.toolbarArea addSubview:button];
        [buttons addObject:button];
        x += 64.0 + METRICS_SPACE_8;
    }
    self.toolbarButtons = buttons;
}

- (void)toolbarClicked:(NSButton *)sender
{
    [self runCommand:objc_getAssociatedObject(sender, "duToken")
           forObject:self.selectedObject];
}

#pragma mark - Commands

// Single routing point shared by toolbar and contextual menu (SPEC section
// 33); availability was already decided by capability-driven button state.
- (void)runCommand:(NSString *)token forObject:(DUStorageObject *)object
{
    if (object == nil) {
        return;
    }

    if ([token isEqualToString:@"verify"]) {
        [self.storageManager verifyObject:object
                               onProgress:nil
                             onCompletion:^(NSError *error) {
            // Backends invoke completions on worker threads; alerts are
            // pure AppKit and must run on the main thread. nil passes
            // through performSelectorOnMainThread unchanged.
            [self performSelectorOnMainThread:
                @selector(verifyFinishedWithError:)
                                   withObject:error
                                waitUntilDone:NO];
        }
                                error:NULL];
        return;
    }

    if ([token isEqualToString:@"mount"] ||
        [token isEqualToString:@"unmount"]) {
        BOOL mounting = [token isEqualToString:@"mount"];
        void (^done)(NSError *, NSString *) =
            ^(NSError *error, NSString *mountPoint) {
            NSDictionary *result = @{
                @"error" : error ?: [NSNull null],
                @"mounting" : @(mounting),
            };
            [self performSelectorOnMainThread:
                @selector(mountFinishedWithResult:)
                                   withObject:result
                                waitUntilDone:NO];
            (void)mountPoint;
        };
        if (mounting) {
            [self.storageManager.backend mountObject:object completion:done];
        } else {
            [self.storageManager.backend unmountObject:object
                                            completion:^(NSError *error) {
                done(error, nil);
            }];
        }
        return;
    }

    if ([token isEqualToString:@"eject"]) {
        [self.storageManager.backend ejectObject:object
                                      completion:^(NSError *error) {
            [self performSelectorOnMainThread:
                @selector(ejectFinishedWithError:)
                                   withObject:error
                                waitUntilDone:NO];
        }];
        return;
    }

    // Erase routes to the Erase tab where the destructive form lives.
    if ([token isEqualToString:@"erase"]) {
        [self.operationController.tabView selectTabViewItemAtIndex:1];
        return;
    }

    if ([token isEqualToString:@"info"]) {
        [self showInfoWindowForObject:object];
        return;
    }

    if ([token isEqualToString:@"newimage"]) {
        /* Sync the source from the CURRENT outline selection right before
         * opening: the panel's read-only field must always match what the
         * user sees highlighted in the sidebar. */
        [self.imagePanelController setSourceObject:self.selectedObject];
        [self.imagePanelController openPanel];
        return;
    }

    // Burn/journaling/convert/resize remain capability-gated but inert;
    // they stay disabled instead of pretending success.
}

// Get Information (SPEC section 33): a titled secondary window showing the
// full field set for the selection; the footer stays where it is.
- (void)showInfoWindowForObject:(DUStorageObject *)object
{
    if (object == nil) {
        return;
    }
    if (_infoWindow == nil) {
        _infoWindow = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 380, 240)
                      styleMask:NSTitledWindowMask | NSClosableWindowMask
                                  | NSMiniaturizableWindowMask
                        backing:NSBackingStoreBuffered
                          defer:NO];
        _infoWindow.releasedWhenClosed = NO;
        _infoWindowController = [[DUInformationController alloc] init];
        // contentView is typed id here; the frame comes from our own
        // content rect minus the titlebar height.
        NSView *content = [[NSView alloc]
            initWithFrame:NSMakeRect(0, 0, 380, 190)];
        content.autoresizingMask =
            NSViewWidthSizable | NSViewHeightSizable;
        _infoWindowController.view.frame = content.bounds;
        _infoWindowController.view.autoresizingMask =
            NSViewWidthSizable | NSViewHeightSizable;
        [content addSubview:_infoWindowController.view];
        _infoWindow.contentView = content;

    }
    // Re-render on every open so the data tracks the latest snapshot even
    // when the window was merely closed, not released.
    [_infoWindowController setObject:object];
    _infoWindow.title = [NSString stringWithFormat:
        NSLocalizedString(@"%@ - Information", nil),
        object.displayName ?: NSLocalizedString(@"Device", nil)];
    [_infoWindow center];
    [_infoWindow makeKeyAndOrderFront:nil];
}

#pragma mark - Selection fan-out (SPEC section 30)

- (void)browserSelectionChanged:(DUStorageObject *)object
{
    self.selectedObject = object;
    [_imagePanelController setSourceObject:object];
    [_operationController refreshForObject:object
                              capabilities:object.capabilities];
    [_informationController setObject:object];
    [self updateToolbarForSelection];
}

- (void)browserRequestCommand:(NSString *)token
                    forObject:(DUStorageObject *)object
{
    [self runCommand:token forObject:object];
}

- (void)updateToolbarForSelection
{
    DUStorageCapabilities *caps = self.selectedObject.capabilities;
    BOOL hasSelection = self.selectedObject != nil;
    NSDictionary<NSString *, NSNumber *> *availability = @{
        @"verify" : @(caps.canVerify),
        @"info" : @(hasSelection),
        @"burn" : @(caps.canBurn),
        @"mount" : @(caps.canMount || caps.canUnmount),
        @"eject" : @(caps.canEject),
        @"journaling" : @(caps.canToggleJournaling),
        @"newimage" : @(caps.canCreateImage),
        @"convert" : @(caps.canConvertImage),
        @"resize" : @(caps.canResizeImage),
    };
    for (NSButton *button in self.toolbarButtons) {
        NSString *token = objc_getAssociatedObject(button, "duToken");
        button.enabled = [availability[token] boolValue];
    }
}

#pragma mark - Command completions (main thread only)

// Backend completions arrive on worker threads; the blocks marshal here so
// alerts and model refreshes never touch AppKit off the main thread.
- (void)verifyFinishedWithError:(NSError *)error
{
    if (error != nil && error.code != DUErrorCancelled) {
        NSRunAlertPanel(
            NSLocalizedString(@"Verify", nil),
            error.localizedDescription
                ?: NSLocalizedString(@"Verification failed.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
    }
}

- (void)ejectFinishedWithError:(NSError *)error
{
    if (error != nil && error.code != DUErrorCancelled) {
        NSRunAlertPanel(
            NSLocalizedString(@"Eject", nil),
            error.localizedDescription
                ?: NSLocalizedString(@"Could not eject.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
    }
}

- (void)mountFinishedWithResult:(NSDictionary *)result
{
    NSError *error = result[@"error"] == [NSNull null]
        ? nil : result[@"error"];
    BOOL mounting = [result[@"mounting"] boolValue];
    if (error != nil) {
        NSRunAlertPanel(
            mounting ? NSLocalizedString(@"Mount", nil)
                     : NSLocalizedString(@"Unmount", nil),
            error.localizedDescription
                ?: NSLocalizedString(@"The operation failed.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    // Model refresh picks up the new mount state asynchronously; the
    // topology notification comes back on the main thread.
    DUStorageManager *manager = self.storageManager;
    NSThread *worker = [[NSThread alloc]
        initWithBlock:^{
        @autoreleasepool {
            [manager refreshWithError:NULL];
        }
    }];
    worker.name = @"DU-Mount-Refresh";
    [worker start];
}

#pragma mark - Notifications

- (void)topologyDidChange:(NSNotification *)note
{
    (void)note;
    NSString *preferred = self.selectedObject.identifier;
    [self.browserController reloadWithPreferredSelection:preferred];
    // Reload re-selects and fires the delegate when the object survives;
    // when it vanished the controller falls back to the first device and
    // notifies through the same path.
}

- (void)operationStateDidChange:(NSNotification *)note
{
    // Any active operation freezes action controls everywhere (ARCHITECTURE.md
    // section 33 device locking is enforced deeper; this is presentation only).
    /* Observer order versus the manager's own DidFinish bookkeeping is
     * unspecified: when this observer runs first the count still contains
     * the operation that just ended, so a plain count check would freeze
     * the strip forever. Ignore operations already in a terminal state. */
    BOOL busy = NO;
    for (DUOperation *operation in
            self.storageManager.operationManager.activeOperations) {
        if (operation.state != DUOperationStateCancelled &&
            operation.state != DUOperationStateCompleted &&
            operation.state != DUOperationStateFailed) {
            busy = YES;
            break;
        }
    }
    [_operationController setControlsEnabled:!busy];

    if (busy) {
        // A new operation supersedes any pending strip teardown.
        [self.stripHideTimer invalidate];
        self.stripHideTimer = nil;
        self.operationStrip.hidden = NO;
        self.stopButton.hidden = NO;
        if ([note.name isEqualToString:DUOperationDidStartNotification]) {
            self.operationBar.doubleValue = 0.0;
            self.operationStatus.stringValue = @"";
        }
        return;
    }

    // Terminal: Stop dies immediately (nothing left to cancel). The strip
    // folds straight away: a hide timer scheduled from inside a marshaled
    // notification lands in whatever run-loop mode is current there and
    // can then never fire, freezing the strip on screen.
    self.stopButton.hidden = YES;
    [self.stripHideTimer invalidate];
    self.stripHideTimer = nil;
    [self hideOperationStrip];
}

- (void)hideOperationStrip
{
    [self.stripHideTimer invalidate];
    self.stripHideTimer = nil;
    self.operationStrip.hidden = YES;
    self.operationBar.doubleValue = 0.0;
    self.operationStatus.stringValue = @"";
    /* Hiding a view whose band no other view covers can leave stale
     * pixels, and a damage scheduled from a timer callback is only
     * flushed with the next X11 event - which may never come. Draw
     * synchronously instead. */
    [[self.window contentView] setNeedsDisplay:YES];
    [self.window display];
}

// Live tool output: every progress callback carries the latest tool line
// (dd byte counts, fsck/mkfs stage lines, copy fractions). The bar tracks
// the operation's monotonic fraction; new lines stream into the log.
- (void)operationDidUpdate:(NSNotification *)note
{
    DUOperation *operation = note.userInfo[kDUUserInfoOperationKey];
    if (operation == nil) {
        return;
    }
    double fraction = operation.progress;
    NSString *message = operation.message ?: @"";
    self.operationBar.doubleValue = fraction * 100.0;
    self.operationStatus.stringValue =
        message.length > 0
            ? message
            : NSLocalizedString(@"Working...", nil);
    if (fraction >= 0.999 && message.length > 0) {
        // Park the final wording on the bottom edge where it survives the
        // strip folding away.
        self.completionLabel.stringValue = message;
    }

    NSString *last = self.lastLoggedMessageByOperation[operation.identifier];
    if (message.length > 0 && ![message isEqualToString:last]) {
        self.lastLoggedMessageByOperation[operation.identifier] = message;
        [_operationController.logView appendLine:
            [NSString stringWithFormat:@"[%lu%%] %@",
                                       (unsigned long)(fraction * 100.0),
                                       message]];
    }
}

- (void)operationDidFail:(NSNotification *)note
{
    DUOperation *operation = note.userInfo[kDUUserInfoOperationKey];
    NSError *error = note.userInfo[kDUUserInfoErrorKey];
    if (operation != nil) {
        [self.lastLoggedMessageByOperation
            removeObjectForKey:operation.identifier];
    }
    if (error != nil && error.code != DUErrorCancelled) {
        NSString *why = error.localizedDescription ?: @"Operation failed.";
        [_operationController.logView appendLine:why];
        self.completionLabel.stringValue = why;
    } else {
        self.completionLabel.stringValue =
            NSLocalizedString(@"Cancelled.", nil);
    }
}

- (void)stopClicked:(id)sender
{
    (void)sender;
    [[self.storageManager operationManager] cancelAllOperations];
}

#pragma mark - Frame persistence (SPEC section 68)

- (NSRect)restoredFrame
{
    NSData *archived =
        [[NSUserDefaults standardUserDefaults]
            dataForKey:kDefaultsWindowFrame];
    if (archived != nil) {
        NSValue *value =
            [NSKeyedUnarchiver unarchiveObjectWithData:archived];
        if ([value isKindOfClass:[NSValue class]]) {
            NSRect frame = value.rectValue;
            if (frame.size.width >= kMinimumWindowWidth &&
                frame.size.height >= kMinimumWindowHeight &&
                !NSIsEmptyRect(frame)) {
                return frame;
            }
        }
    }
    return NSMakeRect(100, 100, kDefaultWindowWidth, kDefaultWindowHeight);
}

- (void)windowDidResize:(NSNotification *)notification
{
    (void)notification;
    [self persistFrame];
}

- (void)windowWillClose:(NSNotification *)notification
{
    (void)notification;
    [self persistFrame];
}

- (void)persistFrame
{
    if (self.window == nil) {
        return;
    }
    NSValue *value = [NSValue valueWithRect:self.window.frame];
    [[NSUserDefaults standardUserDefaults]
        setObject:[NSKeyedArchiver archivedDataWithRootObject:value]
           forKey:kDefaultsWindowFrame];
}

@end
