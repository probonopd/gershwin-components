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
#import "DUImagePanelController.h"
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
#import "DUStorageDevice.h"
#import "DUDiskImage.h"
#import "DUSHA256.h"
#import "DUPreferencesController.h"

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

// Kept so the View > Show Sidebar toggle can reflow the operation area.
@property (nonatomic, strong) NSView *browserPaneView;
@property (nonatomic, strong) NSView *operationAreaView;
@property (nonatomic, strong) NSBox *verticalSeparatorView;
// Remembered so toggling the sidebar back on restores the right width.
@property (nonatomic, assign) BOOL sidebarVisible;

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
@property (nonatomic, strong) DUImagePanelController *imageOpsPanelController;
@property (nonatomic, strong) NSWindow *infoWindow;
@property (nonatomic, strong) DUInformationController *infoWindowController;

// Registers an image-file path in the "registered images" preference so it
// appears in the sidebar (DUAdditionalImages is read by every backend's
// discovery). Idempotent; refreshes the browser snapshot.
- (void)registerImagePathInSidebar:(NSString *)path;
// Mounts a single disk-image file; alertOnFailure controls whether a
// failure surfaces as a panel (Open menu) or is swallowed (drops).
- (void)mountImageAtPath:(NSString *)path alertOnFailure:(BOOL)alert;
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
    // Let the theme draw the window's natural content background; do not
    // paint over it with an explicit color.
    [super drawRect:dirtyRect];
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

    // Convert/Resize/Burn share one mode-switched panel.
    _imageOpsPanelController =
        [[DUImagePanelController alloc] initWithStorageManager:manager
                                                        logView:_operationController.logView];

    _informationController = [[DUInformationController alloc] init];

    [self buildLayoutInWindow:window];
    [self buildToolbarButtons];
    // Start with every command control disabled; updateToolbarForSelection
    // re-enables only what the selected object's capabilities permit, so the
    // toolbar never advertises an operation no backend implements.
    [self updateToolbarForSelection];

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

    self.browserPaneView = browserPane;
    self.operationAreaView = operationArea;
    self.verticalSeparatorView = verticalSeparator;
    self.sidebarVisible = YES;
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

    if ([token isEqualToString:@"convert"] ||
        [token isEqualToString:@"resize"] || [token isEqualToString:@"burn"]) {
        DUImagePanelMode mode =
            [token isEqualToString:@"convert"]
                ? DUImagePanelModeConvert
                : [token isEqualToString:@"resize"]
                      ? DUImagePanelModeResize
                      : DUImagePanelModeBurn;
        [self.imageOpsPanelController setMode:mode];
        [self.imageOpsPanelController setSourceObject:self.selectedObject];
        [self.imageOpsPanelController openPanel];
        return;
    }

    if ([token isEqualToString:@"blankdisc"] ||
        [token isEqualToString:@"copydisc"] ||
        [token isEqualToString:@"verifydisc"]) {
        if ([token isEqualToString:@"blankdisc"]) {
            [self commandEraseDisc:self];
        } else if ([token isEqualToString:@"copydisc"]) {
            [self commandCopyDisc:self];
        } else {
            [self commandVerifyDisc:self];
        }
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

#pragma mark - Main menu actions

// The menu (built in DUApplicationDelegate) targets this controller; every
// command routes through the same token dispatcher the toolbar uses so the
// menu and the buttons never diverge (SPEC section 33).
- (IBAction)commandNewImageFromDevice:(id)sender
{
    (void)sender;
    [self runCommand:@"newimage" forObject:self.selectedObject];
}

- (IBAction)commandMount:(id)sender
{
    (void)sender;
    [self runCommand:@"mount" forObject:self.selectedObject];
}

- (IBAction)commandUnmount:(id)sender
{
    (void)sender;
    [self runCommand:@"unmount" forObject:self.selectedObject];
}

- (IBAction)commandEject:(id)sender
{
    (void)sender;
    [self runCommand:@"eject" forObject:self.selectedObject];
}

- (IBAction)commandGetInfo:(id)sender
{
    (void)sender;
    [self runCommand:@"info" forObject:self.selectedObject];
}

- (IBAction)commandVerify:(id)sender
{
    (void)sender;
    [self runCommand:@"verify" forObject:self.selectedObject];
}

- (IBAction)commandConvert:(id)sender
{
    (void)sender;
    [self runCommand:@"convert" forObject:self.selectedObject];
}

- (IBAction)commandBurn:(id)sender
{
    (void)sender;
    [self runCommand:@"burn" forObject:self.selectedObject];
}

- (IBAction)commandResize:(id)sender
{
    (void)sender;
    [self runCommand:@"resize" forObject:self.selectedObject];
}

// Erase a rewritable optical disc. Destructive, so we confirm first; the
// backend reports clearly when the inserted media is not rewritable.
- (IBAction)commandEraseDisc:(id)sender
{
    (void)sender;
    DUStorageObject *object = self.selectedObject;
    if (![object isKindOfClass:[DUStorageDevice class]] ||
        !((DUStorageDevice *)object).optical) {
        return;
    }
    NSInteger rc = NSRunAlertPanel(
        NSLocalizedString(@"Erase Disc", nil),
        NSLocalizedString(@"Erasing the disc will permanently remove all "
                          @"data on it. This cannot be undone. Continue?",
                          nil),
        NSLocalizedString(@"Erase", nil),
        NSLocalizedString(@"Cancel", nil), nil);
    if (rc != NSAlertDefaultReturn) {
        return;
    }
    self.completionLabel.stringValue =
        NSLocalizedString(@"Erasing disc...", nil);
    NSError *error = nil;
    DUOperation *op = [self.storageManager
        blankOpticalDisc:object
                 options:@{ kDUDiscBlankMethodKey : kDUDiscBlankFastKey }
              onProgress:^(double progress, NSString *msg) {
            [self runOnMain:^{
                self.completionLabel.stringValue = msg ?: @"";
                (void)progress;
            }];
        }
            onCompletion:^(NSError *err) {
            [self runOnMain:^{
                if (err != nil && err.code != DUErrorCancelled) {
                    NSRunAlertPanel(
                        NSLocalizedString(@"Erase Disc", nil),
                        err.localizedDescription
                            ?: NSLocalizedString(
                                   @"The disc could not be erased.", nil),
                        NSLocalizedString(@"OK", nil), nil, nil);
                    self.completionLabel.stringValue =
                        err.localizedDescription ?: @"";
                } else if (err == nil) {
                    self.completionLabel.stringValue =
                        NSLocalizedString(@"Disc erased successfully.", nil);
                }
            }];
        }
                  error:&error];
    if (op == nil && error != nil) {
        NSRunAlertPanel(NSLocalizedString(@"Erase Disc", nil),
                        error.localizedDescription
                            ?: NSLocalizedString(
                                   @"The disc could not be erased.", nil),
                        NSLocalizedString(@"OK", nil), nil, nil);
    }
}

// Copy the disc in the selected drive to an image file (whole-disc read).
- (IBAction)commandCopyDisc:(id)sender
{
    (void)sender;
    DUStorageObject *object = self.selectedObject;
    if (![object isKindOfClass:[DUStorageDevice class]] ||
        !((DUStorageDevice *)object).optical) {
        return;
    }
    NSSavePanel *save = [NSSavePanel savePanel];
    save.title = NSLocalizedString(@"Copy Disc To Image", nil);
    save.nameFieldStringValue = @"Optical Disc.iso";
    save.allowedFileTypes = @[ @"iso", @"cdr", @"img" ];
    if ([save runModal] != NSFileHandlingPanelOKButton) {
        return;
    }
    NSString *destination = save.filename;
    if (destination.length == 0) {
        return;
    }
    self.completionLabel.stringValue =
        NSLocalizedString(@"Copying disc...", nil);
    NSError *error = nil;
    DUOperation *op = [self.storageManager
        createImageFromObject:object
                      options:@{ @"path" : destination, @"format" : @"raw" }
                   onProgress:^(double progress, NSString *msg) {
            [self runOnMain:^{
                self.completionLabel.stringValue = msg ?: @"";
                (void)progress;
            }];
        }
                 onCompletion:^(NSError *err) {
            [self runOnMain:^{
                if (err != nil && err.code != DUErrorCancelled) {
                    NSRunAlertPanel(
                        NSLocalizedString(@"Copy Disc", nil),
                        err.localizedDescription
                            ?: NSLocalizedString(
                                   @"The disc could not be copied.", nil),
                        NSLocalizedString(@"OK", nil), nil, nil);
                    self.completionLabel.stringValue =
                        err.localizedDescription ?: @"";
                } else if (err == nil) {
                    self.completionLabel.stringValue =
                        NSLocalizedString(@"Disc copied successfully.", nil);
                }
            }];
        }
                          error:&error];
    if (op == nil && error != nil) {
        NSRunAlertPanel(NSLocalizedString(@"Copy Disc", nil),
                        error.localizedDescription
                            ?: NSLocalizedString(
                                   @"The disc could not be copied.", nil),
                        NSLocalizedString(@"OK", nil), nil, nil);
    }
}

// Verify a burned disc by reading its data back and comparing it against the
// source image the user points us at.
- (IBAction)commandVerifyDisc:(id)sender
{
    (void)sender;
    DUStorageObject *object = self.selectedObject;
    if (![object isKindOfClass:[DUStorageDevice class]] ||
        !((DUStorageDevice *)object).optical) {
        return;
    }
    NSOpenPanel *open = [NSOpenPanel openPanel];
    open.title = NSLocalizedString(@"Select Source Image", nil);
    open.canChooseDirectories = NO;
    open.canChooseFiles = YES;
    open.allowedFileTypes = @[ @"iso", @"cdr", @"img", @"dmg" ];
    if ([open runModal] != NSFileHandlingPanelOKButton) {
        return;
    }
    NSString *imagePath = open.filename;
    if (imagePath.length == 0) {
        return;
    }
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:imagePath
                                                          error:NULL];
    DUDiskImage *image = [[DUDiskImage alloc]
        initWithIdentifier:[@"verify-" stringByAppendingString:imagePath]];
    image.path = imagePath;
    image.sizeBytes = [attrs fileSize];

    self.completionLabel.stringValue =
        NSLocalizedString(@"Verifying disc...", nil);
    NSError *error = nil;
    DUOperation *op = [self.storageManager
        verifyDisc:object
      againstImage:image
         onProgress:^(double progress, NSString *msg) {
            [self runOnMain:^{
                self.completionLabel.stringValue = msg ?: @"";
                (void)progress;
            }];
        }
       onCompletion:^(NSError *err) {
            [self runOnMain:^{
                if (err != nil && err.code != DUErrorCancelled) {
                    NSRunAlertPanel(
                        NSLocalizedString(@"Verify Disc", nil),
                        err.localizedDescription
                            ?: NSLocalizedString(@"Verification failed.",
                                                 nil),
                        NSLocalizedString(@"OK", nil), nil, nil);
                    self.completionLabel.stringValue =
                        err.localizedDescription ?: @"";
                } else if (err == nil) {
                    self.completionLabel.stringValue =
                        NSLocalizedString(@"Disc verified successfully.", nil);
                }
            }];
        }
              error:&error];
    if (op == nil && error != nil) {
        NSRunAlertPanel(NSLocalizedString(@"Verify Disc", nil),
                        error.localizedDescription
                            ?: NSLocalizedString(@"Verification failed.",
                                                 nil),
                        NSLocalizedString(@"OK", nil), nil, nil);
    }
}

// Re-reads the whole topology; the refresh shortcuts and the menu share it
// with the launch-time discovery worker (ARCHITECTURE.md section 39).
- (IBAction)commandRefresh:(id)sender
{
    (void)sender;
    DUStorageManager *manager = self.storageManager;
    NSThread *worker = [[NSThread alloc]
        initWithBlock:^{
        @autoreleasepool {
            [manager refreshWithError:NULL];
        }
    }];
    worker.name = @"DU-menu-refresh";
    [worker start];
}

// The sidebar hosts the device tree; hiding it lets the operation area use
// the full window width. The vertical divider tracks the sidebar so the
// split never floats on its own.
- (IBAction)commandToggleSidebar:(id)sender
{
    (void)sender;
    BOOL show = !self.sidebarVisible;
    self.sidebarVisible = show;
    self.browserPaneView.hidden = !show;
    self.verticalSeparatorView.hidden = !show;

    CGFloat browserWidth = kBrowserWidth + kSeparatorThickness;
    NSView *contentView = self.window.contentView;
    NSRect contentFrame = contentView.frame;
    NSRect opFrame = self.operationAreaView.frame;
    if (show) {
        opFrame.origin.x = browserWidth;
        opFrame.size.width = NSWidth(contentFrame) - browserWidth;
    } else {
        opFrame.origin.x = 0.0;
        opFrame.size.width = NSWidth(contentFrame);
    }
    self.operationAreaView.frame = opFrame;
}

- (IBAction)commandClose:(id)sender
{
    [self.window performClose:sender];
}

// No bundled help book yet; point the user at the one place the app explains
// itself rather than opening a dead link.
- (IBAction)commandHelp:(id)sender
{
    (void)sender;
    NSRunInformationalAlertPanel(
        NSLocalizedString(@"Disk Utility Help", nil),
        NSLocalizedString(
            @"Select a disk or volume in the sidebar, then use the toolbar "
            @"or the menus to verify, mount, image, convert, resize or burn. "
            @"Operations stream their progress in the log at the bottom.",
            nil),
        NSLocalizedString(@"OK", nil), nil, nil);
}

// Menu validation keeps command items honest: they enable only when the
// selection and its capabilities actually support the operation, instead of
// firing and silently doing nothing.
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = menuItem.action;
    DUStorageObject *selection = self.selectedObject;
    if (selection == nil) {
        if (action == @selector(commandNewImageFromDevice:) ||
            action == @selector(commandMount:) ||
            action == @selector(commandUnmount:) ||
            action == @selector(commandEject:) ||
            action == @selector(commandGetInfo:) ||
            action == @selector(commandVerify:) ||
            action == @selector(commandConvert:) ||
            action == @selector(commandBurn:) ||
            action == @selector(commandResize:) ||
            action == @selector(commandAddChecksum:) ||
            action == @selector(commandVerifyChecksum:) ||
            action == @selector(commandScanImageForRestore:)) {
            return NO;
        }
        // No selection: every other command the controller implements stays
        // available (Refresh, Close, Help, view toggles).  We must not call
        // super here -- NSWindowController does not implement validateMenuItem:
        // and doing so throws on every menu update.
        return (action == NULL) ? NO : [self respondsToSelector:action];
    }
    DUStorageCapabilities *caps = selection.capabilities;
    if (action == @selector(commandConvert:)) {
        return caps.canConvertImage;
    }
    if (action == @selector(commandBurn:)) {
        return caps.canBurn;
    }
    if (action == @selector(commandResize:)) {
        return caps.canResizeImage;
    }
    if (action == @selector(commandMount:)) {
        return caps.canMount;
    }
    if (action == @selector(commandUnmount:)) {
        return caps.canUnmount;
    }
    if (action == @selector(commandEject:)) {
        return caps.canEject;
    }
    if (action == @selector(commandGetInfo:) ||
        action == @selector(commandVerify:) ||
        action == @selector(commandNewImageFromDevice:)) {
        return YES;
    }
    // Image-creation verbs need a backend that implements them.
    if (action == @selector(commandBlankImage:) ||
        action == @selector(commandImageFromFolder:)) {
        return [self.activeBackend
            respondsToSelector:@selector
            (createBlankImageAtPath:size:format:progress:completion:)];
    }
    if (action == @selector(commandOpenDiskImage:)) {
        return [self.activeBackend
            respondsToSelector:@selector(mountFileImageAtPath:completion:)];
    }
    if (action == @selector(commandEraseDisc:)) {
        return caps.canBlankDisc;
    }
    if (action == @selector(commandCopyDisc:)) {
        return [selection isKindOfClass:[DUStorageDevice class]] &&
            ((DUStorageDevice *)selection).optical && caps.canCreateImage;
    }
    if (action == @selector(commandVerifyDisc:)) {
        return caps.canVerifyDisc;
    }
    // These do not depend on the current selection.
    if (action == @selector(commandPreferences:) ||
        action == @selector(commandToggleToolbar:) ||
        action == @selector(commandToggleStatusBar:) ||
        action == @selector(commandCustomizeToolbar:) ||
        action == @selector(commandShowAllDevices:) ||
        action == @selector(commandShowOnlyVolumes:)) {
        return YES;
    }
    // Checksum and restore wiring act only on a selected disk-image file.
    if (action == @selector(commandAddChecksum:) ||
        action == @selector(commandVerifyChecksum:) ||
        action == @selector(commandScanImageForRestore:)) {
        DUStorageObject *sel = self.selectedObject;
        return sel != nil && sel.type == DUStorageObjectTypeDiskImage;
    }
    // Anything else the controller implements is enabled; super would throw
    // because NSWindowController has no validateMenuItem:.
    return (action == NULL) ? NO : [self respondsToSelector:action];
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

#pragma mark - File: blank / folder / open image

- (id<DUStorageBackend>)activeBackend
{
    return self.storageManager.backend;
}

// GNUstep has no libdispatch; marshal UI work to the main thread with
// performSelectorOnMainThread instead of dispatch_async.
- (void)runOnMain:(void (^)(void))block
{
    [self performSelectorOnMainThread:@selector(_runBlock:)
                           withObject:[block copy]
                        waitUntilDone:NO];
}

- (void)_runBlock:(id)blockObject
{
    void (^block)(void) = blockObject;
    block();
}

- (NSString *)promptTextWithTitle:(NSString *)title
                          message:(NSString *)message
                     defaultValue:(NSString *)defaultValue
{
    const CGFloat m = METRICS_CONTENT_SIDE_MARGIN;       // 24
    const CGFloat b = METRICS_CONTENT_BOTTOM_MARGIN;     // 20
    const CGFloat W = 320.0;
    const CGFloat H = 130.0;
    NSWindow *panel = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, W, H)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = title;
    NSView *content = panel.contentView;
    NSTextField *label =
        [[NSTextField alloc] initWithFrame:NSMakeRect(m, 90, W - 2 * m, 20)];
    label.editable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = METRICS_FONT_SYSTEM_REGULAR_13;
    label.stringValue = message ?: @"";
    [content addSubview:label];
    NSTextField *field = [[NSTextField alloc]
        initWithFrame:NSMakeRect(m, 60, W - 2 * m,
                                 METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    field.font = METRICS_FONT_SYSTEM_REGULAR_13;
    field.stringValue = defaultValue ?: @"";
    [content addSubview:field];
    NSButton *ok = [[NSButton alloc]
        initWithFrame:NSMakeRect(W - m - METRICS_BUTTON_MIN_WIDTH, b,
                                METRICS_BUTTON_MIN_WIDTH,
                                METRICS_BUTTON_HEIGHT)];
    ok.title = NSLocalizedString(@"OK", nil);
    ok.keyEquivalent = @"\r";
    ok.tag = 1;
    [ok setAction:@selector(stopModalPanel:)];
    [ok setTarget:self];
    [content addSubview:ok];
    NSButton *cancel = [[NSButton alloc]
        initWithFrame:NSMakeRect(W - m - METRICS_BUTTON_MIN_WIDTH * 2 -
                                     METRICS_SPACE_12,
                                 b, METRICS_BUTTON_MIN_WIDTH,
                                 METRICS_BUTTON_HEIGHT)];
    cancel.title = NSLocalizedString(@"Cancel", nil);
    cancel.tag = 0;
    [cancel setAction:@selector(stopModalPanel:)];
    [cancel setTarget:self];
    [content addSubview:cancel];
    [panel makeKeyAndOrderFront:self];
    NSInteger rc = [NSApp runModalForWindow:panel];
    [panel orderOut:self];
    if (rc != 1) {
        return nil;
    }
    return [field stringValue];
}

- (void)stopModalPanel:(id)sender
{
    [NSApp stopModalWithCode:[(NSButton *)sender tag]];
}

- (void)commandBlankImage:(id)sender
{
    (void)sender;
    id<DUStorageBackend> backend = [self activeBackend];
    if (![backend respondsToSelector:@selector(createBlankImageAtPath:
                                                                   size:
                                                                 format:
                                                             progress:
                                                           completion:)]) {
        NSRunAlertPanel(
            NSLocalizedString(@"Blank Image", nil),
            NSLocalizedString(@"This backend cannot create blank images.",
                              nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    NSSavePanel *save = [NSSavePanel savePanel];
    save.title = NSLocalizedString(@"Create Blank Image", nil);
    save.nameFieldStringValue = @"New Image.img";
    if ([save runModal] != NSFileHandlingPanelOKButton) {
        return;
    }
    NSString *destination = save.filename;
    if (destination.length == 0) {
        return;
    }
    NSString *sizeText = [self
        promptTextWithTitle:NSLocalizedString(@"Image Size", nil)
                    message:NSLocalizedString(
                        @"Enter the image size in megabytes.", nil)
               defaultValue:@"100"];
    if (sizeText == nil) {
        return;
    }
    long long megs = (long long)[sizeText longLongValue];
    if (megs <= 0) {
        megs = 100;
    }
    unsigned long long bytes = (unsigned long long)megs * 1024ull * 1024ull;
    self.completionLabel.stringValue =
        NSLocalizedString(@"Creating blank image...", nil);
    [backend createBlankImageAtPath:destination
                               size:bytes
                             format:@"raw"
                           progress:^(double progress, NSString *msg) {
                               [self runOnMain:^{
                                 self.completionLabel.stringValue =
                                     msg ?: @"";
                                 (void)progress;
                               }];
                           }
                         completion:^(NSError *error) {
                             [self runOnMain:^{
                               if (error != nil) {
                                 NSRunAlertPanel(
                                     NSLocalizedString(@"Blank Image", nil),
                                     error.localizedDescription
                                         ?: NSLocalizedString(
                                                @"The image could not be "
                                                @"created.",
                                                nil),
                                     NSLocalizedString(@"OK", nil), nil, nil);
                                 self.completionLabel.stringValue =
                                     error.localizedDescription ?: @"";
                               } else {
                                 self.completionLabel.stringValue =
                                     NSLocalizedString(
                                         @"Blank image created.", nil);
                               }
                             }];
                         }];
}

- (void)commandImageFromFolder:(id)sender
{
    (void)sender;
    id<DUStorageBackend> backend = [self activeBackend];
    if (![backend respondsToSelector:@selector
                  (createImageFromFolder:
                              destination:
                              filesystem:
                                progress:
                              completion:)]) {
        NSRunAlertPanel(
            NSLocalizedString(@"Image From Folder", nil),
            NSLocalizedString(@"This backend cannot image folders.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    NSOpenPanel *open = [NSOpenPanel openPanel];
    open.title = NSLocalizedString(@"Select Folder", nil);
    open.canChooseDirectories = YES;
    open.canChooseFiles = NO;
    if ([open runModal] != NSFileHandlingPanelOKButton) {
        return;
    }
    NSString *folder = open.filename;
    if (folder.length == 0) {
        return;
    }
    NSSavePanel *save = [NSSavePanel savePanel];
    save.title = NSLocalizedString(@"Save Image As", nil);
    save.nameFieldStringValue = @"Folder Image.img";
    if ([save runModal] != NSFileHandlingPanelOKButton) {
        return;
    }
    NSString *destination = save.filename;
    if (destination.length == 0) {
        return;
    }
    self.completionLabel.stringValue =
        NSLocalizedString(@"Creating image from folder...", nil);
    [backend
        createImageFromFolder:folder
                  destination:destination
                  filesystem:@"vfat"
                    progress:^(double progress, NSString *msg) {
                        [self runOnMain:^{
                          self.completionLabel.stringValue = msg ?: @"";
                          (void)progress;
                        }];
                    }
                  completion:^(NSError *error) {
                      [self runOnMain:^{
                        if (error != nil) {
                            NSRunAlertPanel(
                                NSLocalizedString(@"Image From Folder", nil),
                                error.localizedDescription
                                    ?: NSLocalizedString(
                                           @"The image could not be created.",
                                           nil),
                                NSLocalizedString(@"OK", nil), nil, nil);
                            self.completionLabel.stringValue =
                                error.localizedDescription ?: @"";
                        } else {
                            self.completionLabel.stringValue =
                                NSLocalizedString(@"Folder image created.",
                                                  nil);
                        }
                      }];
                  }];
}

- (void)commandOpenDiskImage:(id)sender
{
    (void)sender;
    id<DUStorageBackend> backend = [self activeBackend];
    if (![backend respondsToSelector:@selector
                   (mountFileImageAtPath:completion:)]) {
        NSRunAlertPanel(
            NSLocalizedString(@"Open Disk Image", nil),
            NSLocalizedString(@"This backend cannot open image files.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    NSOpenPanel *open = [NSOpenPanel openPanel];
    open.title = NSLocalizedString(@"Open Disk Image", nil);
    open.canChooseDirectories = NO;
    open.canChooseFiles = YES;
    if ([open runModal] != NSFileHandlingPanelOKButton) {
        return;
    }
    NSString *file = open.filename;
    if (file.length == 0) {
        return;
    }
    [self openDiskImageAtPath:file];
}

// Mounts a single disk-image file and refreshes the browser; shared by
// File > Open Disk Image and image-file drops onto the left pane.
- (void)openDiskImageAtPath:(NSString *)path
{
    // Register first so the image appears in the sidebar even when the
    // mount itself fails (e.g. missing loop-device privileges).
    [self registerImagePathInSidebar:path];
    [self mountImageAtPath:path alertOnFailure:YES];
}

// Registers an image-file path in the "registered images" preference
// (DUAdditionalImages).  Every backend's discovery reads that list and turns
// each path into a DUDiskImage root, so the dropped/opened file shows up in
// the sidebar.  Idempotent and resilient to vanished files (discovery skips
// paths that no longer exist).
- (void)registerImagePathInSidebar:(NSString *)path
{
    if (path.length == 0) {
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *existing =
        [defaults arrayForKey:@"DUAdditionalImages"] ?: @[];
    if ([existing containsObject:path]) {
        [self.storageManager refreshWithError:NULL];
        return;
    }
    NSMutableArray<NSString *> *updated =
        [NSMutableArray arrayWithArray:existing];
    [updated addObject:path];
    [defaults setObject:[updated copy] forKey:@"DUAdditionalImages"];
    [self.storageManager refreshWithError:NULL];
}

// Mounts a single disk-image file.  alertOnFailure=YES surfaces a panel on
// failure (File > Open Disk Image); =NO swallows it because the image is
// already listed in the sidebar after a drop and a modal alert per file
// would be noisy.
- (void)mountImageAtPath:(NSString *)path alertOnFailure:(BOOL)alert
{
    id<DUStorageBackend> backend = [self activeBackend];
    if (![backend respondsToSelector:@selector
                   (mountFileImageAtPath:completion:)]) {
        return;
    }
    self.completionLabel.stringValue =
        NSLocalizedString(@"Mounting disk image...", nil);
    [backend
        mountFileImageAtPath:path
                   completion:^(NSError *error, NSString *mountPoint) {
                       [self runOnMain:^{
                         if (error != nil) {
                             if (alert) {
                                 NSRunAlertPanel(
                                     NSLocalizedString(@"Open Disk Image",
                                                       nil),
                                     error.localizedDescription
                                         ?: NSLocalizedString(
                                                @"The disk image could not "
                                                @"be mounted.",
                                                nil),
                                     NSLocalizedString(@"OK", nil), nil,
                                     nil);
                             }
                             self.completionLabel.stringValue =
                                 error.localizedDescription ?: @"";
                         } else {
                             [self.completionLabel
                                 setStringValue:
                                     [NSString
                                         stringWithFormat:
                                             NSLocalizedString(
                                                 @"Mounted at %@", nil),
                                             mountPoint]];
                             [self.storageManager refreshWithError:NULL];
                         }
                       }];
                   }];
}

#pragma mark - DUDeviceBrowserDelegate (image-file drops)

// Image files dropped onto the left pane are added to the sidebar (and
// mounted when the backend can, silently) so they appear in the list exactly
// as if opened through File > Open Disk Image.
- (void)browserDidDropImageFiles:(NSArray<NSURL *> *)urls
{
    for (NSURL *url in urls) {
        NSString *path = [url path];
        if (path.length == 0) {
            continue;
        }
        [self registerImagePathInSidebar:path];
        [self mountImageAtPath:path alertOnFailure:NO];
    }
}

#pragma mark - Images: checksum and restore wiring

- (NSString *)sha256OfFile:(NSString *)path
{
    DUSHA256 *context = [[DUSHA256 alloc] init];
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) {
        return nil;
    }
    NSData *chunk = nil;
    while ((chunk = [handle readDataOfLength:(1 << 16)]).length > 0) {
        [context updateWithData:chunk];
    }
    [handle closeFile];
    return [context finalHex];
}

- (BOOL)selectedObjectIsImageFile:(NSString **)outPath
{
    DUStorageObject *selection = self.selectedObject;
    if (selection == nil ||
        selection.type != DUStorageObjectTypeDiskImage) {
        return NO;
    }
    DUDiskImage *image = (DUDiskImage *)selection;
    NSString *file = image.path ?: image.backendPath;
    if (file.length == 0) {
        return NO;
    }
    if (outPath != NULL) {
        *outPath = file;
    }
    return YES;
}

- (void)commandAddChecksum:(id)sender
{
    (void)sender;
    NSString *file = nil;
    if (![self selectedObjectIsImageFile:&file]) {
        return;
    }
    self.completionLabel.stringValue =
        NSLocalizedString(@"Computing checksum...", nil);
    // Hash off the main thread (images can be large); report via runOnMain.
    [NSThread detachNewThreadSelector:@selector(hashAndWriteSidecarForFile:)
                             toTarget:self
                           withObject:file];
}

- (void)hashAndWriteSidecarForFile:(NSString *)file
{
    @autoreleasepool {
        NSString *digest = [self sha256OfFile:file];
        [self runOnMain:^{
            if (digest == nil) {
                self.completionLabel.stringValue =
                    NSLocalizedString(@"Checksum failed.", nil);
                return;
            }
            NSString *sidecar = [file stringByAppendingString:@".sha256sum"];
            NSString *line = [NSString
                stringWithFormat:@"%@  %@\n", digest,
                                 [file lastPathComponent]];
            NSError *writeError = nil;
            [line writeToFile:sidecar
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:&writeError];
            self.completionLabel.stringValue =
                writeError == nil
                    ? [NSString
                          stringWithFormat:NSLocalizedString(
                                               @"Checksum written to %@",
                                               nil),
                                           sidecar]
                    : NSLocalizedString(@"Checksum write failed.", nil);
        }];
    }
}

- (void)commandVerifyChecksum:(id)sender
{
    (void)sender;
    NSString *file = nil;
    if (![self selectedObjectIsImageFile:&file]) {
        return;
    }
    NSString *sidecar = [file stringByAppendingString:@".sha256sum"];
    NSError *readError = nil;
    NSString *contents = [NSString stringWithContentsOfFile:sidecar
                                                   encoding:NSUTF8StringEncoding
                                                      error:&readError];
    if (contents == nil) {
        NSRunAlertPanel(
            NSLocalizedString(@"Verify Checksum", nil),
            NSLocalizedString(@"No checksum sidecar file was found for this "
                              @"image.",
                              nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    NSString *stored = nil;
    for (NSString *token in
         [contents componentsSeparatedByString:@" "]) {
        if (token.length > 0) {
            stored = token;
            break;
        }
    }
    if (stored.length == 0) {
        NSRunAlertPanel(
            NSLocalizedString(@"Verify Checksum", nil),
            NSLocalizedString(@"The checksum sidecar file is malformed.", nil),
            NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    self.completionLabel.stringValue =
        NSLocalizedString(@"Verifying checksum...", nil);
    [NSThread detachNewThreadSelector:@selector(hashAndCompareWithArguments:)
                             toTarget:self
                           withObject:@[ file, stored ]];
}

- (void)hashAndCompareWithArguments:(NSArray *)arguments
{
    NSString *file = arguments[0];
    NSString *stored = arguments[1];
    @autoreleasepool {
        NSString *computed = [self sha256OfFile:file];
        [self runOnMain:^{
            BOOL match = [computed isEqualToString:stored];
            self.completionLabel.stringValue =
                match ? NSLocalizedString(@"Checksum verified.", nil)
                      : NSLocalizedString(@"Checksum mismatch.", nil);
            if (!match) {
                NSRunAlertPanel(
                    NSLocalizedString(@"Verify Checksum", nil),
                    NSLocalizedString(
                        @"The image no longer matches its stored checksum.",
                        nil),
                    NSLocalizedString(@"OK", nil), nil, nil);
            }
        }];
    }
}

- (void)commandScanImageForRestore:(id)sender
{
    (void)sender;
    DUStorageObject *selection = self.selectedObject;
    if (selection == nil ||
        selection.type != DUStorageObjectTypeDiskImage) {
        return;
    }
    [self.operationController showRestorePaneWithSource:selection];
}

#pragma mark - View toggles

- (void)commandShowAllDevices:(id)sender
{
    (void)sender;
    self.browserController.showOnlyVolumes = NO;
    [self.browserController
        reloadWithPreferredSelection:self.selectedObject.identifier];
}

- (void)commandShowOnlyVolumes:(id)sender
{
    (void)sender;
    self.browserController.showOnlyVolumes = YES;
    [self.browserController
        reloadWithPreferredSelection:self.selectedObject.identifier];
}

- (void)commandToggleToolbar:(id)sender
{
    (void)sender;
    [self.toolbarArea setHidden:![self.toolbarArea isHidden]];
    [self.window.contentView setNeedsDisplay:YES];
}

- (void)commandToggleStatusBar:(id)sender
{
    (void)sender;
    [self.completionLabel setHidden:![self.completionLabel isHidden]];
    [self.window.contentView setNeedsDisplay:YES];
}

- (void)commandCustomizeToolbar:(id)sender
{
    (void)sender;
    NSDictionary<NSString *, NSString *> *labels = @{
        @"verify" : NSLocalizedString(@"Verify", nil),
        @"info" : NSLocalizedString(@"Get Info", nil),
        @"burn" : NSLocalizedString(@"Burn", nil),
        @"mount" : NSLocalizedString(@"Mount / Unmount", nil),
        @"eject" : NSLocalizedString(@"Eject", nil),
        @"journaling" : NSLocalizedString(@"Journaling", nil),
        @"newimage" : NSLocalizedString(@"New Image", nil),
        @"convert" : NSLocalizedString(@"Convert", nil),
        @"resize" : NSLocalizedString(@"Resize", nil),
    };
    const CGFloat m = METRICS_CONTENT_SIDE_MARGIN;
    const CGFloat b = METRICS_CONTENT_BOTTOM_MARGIN;
    const CGFloat W = 280.0;
    const CGFloat H = 250.0;
    NSWindow *panel = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, W, H)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = NSLocalizedString(@"Customize Toolbar", nil);
    NSView *content = panel.contentView;
    NSMutableArray<NSArray *> *pairs = [NSMutableArray array];
    __block CGFloat y =
        H - METRICS_SPACE_20 - METRICS_RADIO_BUTTON_SIZE;
    [labels enumerateKeysAndObjectsUsingBlock:^(
                NSString *token, NSString *label, BOOL *stop) {
        (void)stop;
        for (NSButton *button in self.toolbarButtons) {
            NSString *btoken =
                objc_getAssociatedObject(button, "duToken");
            if ([btoken isEqualToString:token]) {
                NSButton *check = [[NSButton alloc]
                    initWithFrame:NSMakeRect(m, y, W - 2 * m,
                                            METRICS_RADIO_BUTTON_SIZE)];
                [check setButtonType:NSSwitchButton];
                check.title = label;
                check.state = [button isHidden] ? NSOffState : NSOnState;
                [content addSubview:check];
                [pairs addObject:@[ button, check ]];
                y -= METRICS_RADIO_BUTTON_LINE_SPACING;
                break;
            }
        }
    }];
    NSButton *ok = [[NSButton alloc]
        initWithFrame:NSMakeRect(W - m - METRICS_BUTTON_MIN_WIDTH, b,
                                METRICS_BUTTON_MIN_WIDTH,
                                METRICS_BUTTON_HEIGHT)];
    ok.title = @"OK";
    ok.keyEquivalent = @"\r";
    ok.tag = 1;
    [ok setAction:@selector(stopModalPanel:)];
    [ok setTarget:self];
    [content addSubview:ok];
    NSButton *cancel = [[NSButton alloc]
        initWithFrame:NSMakeRect(W - m - METRICS_BUTTON_MIN_WIDTH * 2 -
                                     METRICS_SPACE_12,
                                 b, METRICS_BUTTON_MIN_WIDTH,
                                 METRICS_BUTTON_HEIGHT)];
    cancel.title = NSLocalizedString(@"Cancel", nil);
    cancel.tag = 0;
    [cancel setAction:@selector(stopModalPanel:)];
    [cancel setTarget:self];
    [content addSubview:cancel];
    [panel makeKeyAndOrderFront:sender];
    NSInteger rc = [NSApp runModalForWindow:panel];
    [panel orderOut:self];
    if (rc != 1) {
        return;
    }
    for (NSArray *pair in pairs) {
        NSButton *button = pair[0];
        NSButton *check = pair[1];
        [button setHidden:(check.state == NSOffState)];
    }
    [self updateToolbarForSelection];
}

#pragma mark - Application: preferences

- (void)commandPreferences:(id)sender
{
    (void)sender;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    const CGFloat m = METRICS_CONTENT_SIDE_MARGIN;       // 24
    const CGFloat b = METRICS_CONTENT_BOTTOM_MARGIN;     // 20
    const CGFloat W = 360.0;
    const CGFloat H = 140.0;
    NSWindow *panel = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, W, H)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = NSLocalizedString(@"Preferences", nil);
    NSView *content = panel.contentView;

    NSButton *details = [[NSButton alloc]
        initWithFrame:NSMakeRect(m, 96, W - 2 * m,
                                 METRICS_RADIO_BUTTON_SIZE)];
    [details setButtonType:NSSwitchButton];
    details.title =
        NSLocalizedString(@"Show volume and partition details", nil);
    details.state = [DUPreferencesController showDetails]
                        ? NSOnState
                        : NSOffState;
    [content addSubview:details];

    NSButton *confirm = [[NSButton alloc]
        initWithFrame:NSMakeRect(m, 76, W - 2 * m,
                                 METRICS_RADIO_BUTTON_SIZE)];
    [confirm setButtonType:NSSwitchButton];
    confirm.title = NSLocalizedString(
        @"Confirm destructive operations", nil);
    confirm.state = [DUPreferencesController confirmDestructiveOperations]
                        ? NSOnState
                        : NSOffState;
    [content addSubview:confirm];

    NSTextField *intervalLabel = [[NSTextField alloc]
        initWithFrame:NSMakeRect(m, 60, 220, 20)];
    intervalLabel.editable = NO;
    intervalLabel.bezeled = NO;
    intervalLabel.drawsBackground = NO;
    intervalLabel.font = METRICS_FONT_SYSTEM_REGULAR_13;
    intervalLabel.stringValue =
        NSLocalizedString(@"Refresh interval (seconds)", nil);
    [content addSubview:intervalLabel];

    NSTextField *interval = [[NSTextField alloc]
        initWithFrame:NSMakeRect(W - m - 80, 60, 80,
                                METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    interval.font = METRICS_FONT_SYSTEM_REGULAR_13;
    interval.stringValue = [NSString
        stringWithFormat:@"%.0f",
                         [DUPreferencesController refreshInterval]];
    [content addSubview:interval];

    NSButton *ok = [[NSButton alloc]
        initWithFrame:NSMakeRect(W - m - METRICS_BUTTON_MIN_WIDTH, b,
                                METRICS_BUTTON_MIN_WIDTH,
                                METRICS_BUTTON_HEIGHT)];
    ok.title = NSLocalizedString(@"OK", nil);
    ok.keyEquivalent = @"\r";
    ok.tag = 1;
    [ok setAction:@selector(stopModalPanel:)];
    [ok setTarget:self];
    [content addSubview:ok];
    NSButton *cancel = [[NSButton alloc]
        initWithFrame:NSMakeRect(W - m - METRICS_BUTTON_MIN_WIDTH * 2 -
                                     METRICS_SPACE_12,
                                 b, METRICS_BUTTON_MIN_WIDTH,
                                 METRICS_BUTTON_HEIGHT)];
    cancel.title = NSLocalizedString(@"Cancel", nil);
    cancel.tag = 0;
    [cancel setAction:@selector(stopModalPanel:)];
    [cancel setTarget:self];
    [content addSubview:cancel];

    [panel makeKeyAndOrderFront:sender];
    NSInteger rc = [NSApp runModalForWindow:panel];
    [panel orderOut:self];
    if (rc != 1) {
        return;
    }

    [defaults setBool:(details.state == NSOnState)
               forKey:@"DUShowDetails"];
    [defaults setBool:(confirm.state == NSOnState)
               forKey:@"DUConfirmDestructiveOperations"];
    double value = [interval.stringValue doubleValue];
    if (value >= 3.0) {
        [defaults setDouble:value forKey:@"DURefreshInterval"];
    }
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
