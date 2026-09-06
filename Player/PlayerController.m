/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerController.h"
#import "AppearanceMetrics.h"
#import <AppKit/NSApplication.h>
#import <AppKit/NSSound.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSButton.h>
#import <AppKit/NSSlider.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSImageView.h>
#import <AppKit/NSProgressIndicator.h>
#import <AppKit/NSAlert.h>
#import <AppKit/NSOpenPanel.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSTimer.h>
#import <Foundation/NSArray.h>
#import "ItemFlowView.h"
#import "RadioStation.h"

@class VideoRenderView;

// Forward declarations for internal methods used by DropTargetView
@interface PlayerController () // class extension
{
    NSString *_modalInputResult;
    NSPanel *_modalInputPanel;
    NSTextField *_modalInputField;
    VideoRenderView *_videoRenderView;
    BOOL _usingStreamPlayer;
    BOOL _soundAlertShown;
    BOOL _suppressFlowSelection;

    // Quit-time fade-out of running sound
    BOOL _quittingAfterFade;
    NSTimer *_fadeTimer;
    NSDate *_fadeStartDate;
    float _fadeStartStreamVolume;
    float _fadeStartAudioVolume;
}
- (void)restoreWindowTitle;
- (void)handleDroppedFiles:(NSArray *)filePaths;
- (NSArray *)scanFolderForMediaFiles:(NSString *)folderPath;
- (void)layoutRadioMode;
- (void)radioStop:(id)sender;
- (void)radioPlaySelected;
- (void)radioPreviousStation;
- (void)radioNextStation;
- (NSString *)_inputDialogWithTitle:(NSString *)title
                            message:(NSString *)message
                        placeholder:(NSString *)placeholder;
- (void)_dismissInputDialog:(id)sender;
- (void)_setupAVPlayerWithURL:(NSURL *)streamURL;
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;
- (void)fadeOutTick:(NSTimer *)timer;
@end

// Default window size (content rect, excl. titlebar)
#define DEFAULT_WINDOW_WIDTH   520.0
#define DEFAULT_WINDOW_HEIGHT  592.0

// Minimum content area size
#define PLAYER_CONTENT_MIN_WIDTH   METRICS_WIN_MIN_WIDTH
#define PLAYER_CONTENT_MIN_HEIGHT  320.0

// Height of the cover-art / video area as a fraction of window height
#define COVER_AREA_FRACTION  0.5

// Height of the metadata text block (3 lines + spacing)
#define METADATA_HEIGHT      56.0

// Control bar heights
#define CONTROL_BAR_HEIGHT   22.0
#define SLIDER_BAR_HEIGHT    20.0

// Overlay bar height in fullscreen
#define OVERLAY_BAR_HEIGHT   50.0

// Overlay auto-hide delay (seconds)
#define OVERLAY_HIDE_DELAY   3.0

// Forward declaration for DropTargetView
@interface PlayerController (MediaKeyHandler)
- (BOOL)handleMediaKey:(unichar)c;
@end

#pragma mark - DropTargetView (drag-and-drop content view)

@interface DropTargetView : NSView
{
@public
    PlayerController *_controller; // non-retained (back-pointer)
}
@end

@implementation DropTargetView

- (void)keyDown:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] > 0) {
        unichar c = [chars characterAtIndex:0];
        NSUInteger flags = [event modifierFlags];
        BOOL hasMod = (flags & (NSCommandKeyMask | NSControlKeyMask | NSAlternateKeyMask)) != 0;
        if (!hasMod && (c == ' ' || c == NSLeftArrowFunctionKey
                            || c == NSRightArrowFunctionKey
                            || c == NSUpArrowFunctionKey
                            || c == NSDownArrowFunctionKey
                            || c == 'm' || c == 'M'))
        {
            if ([_controller handleMediaKey:c])
                return;
        }
    }
    [super keyDown:event];
}

- (instancetype)initWithFrame:(NSRect)frame controller:(PlayerController *)controller
{
    self = [super initWithFrame:frame];
    if (self) {
        _controller = controller;
        [self registerForDraggedTypes:@[NSFilenamesPboardType]];
    }
    return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pboard = [sender draggingPasteboard];
    if ([[pboard types] containsObject:NSFilenamesPboardType]) {
        [[_controller mainWindow] setTitle:@"Drop files here to add to playlist…"];
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender
{
    [_controller restoreWindowTitle];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pboard = [sender draggingPasteboard];
    if ([[pboard types] containsObject:NSFilenamesPboardType]) {
        NSArray *files = [pboard propertyListForType:NSFilenamesPboardType];
        if ([files count] > 0 && _controller) {
            [_controller handleDroppedFiles:files];
            return YES;
        }
    }
    return NO;
}

@end

#pragma mark - VideoRenderView (custom NSView that draws RGBA frame data)

/**
 * Displays raw RGBA video frame data by creating NSBitmapImageRep
 * + NSImage in drawRect: from stored raw data. Uses window-level
 * display to ensure GNUstep flushes the backing store to screen.
 */
@interface VideoRenderView : NSView
{
    NSBitmapImageRep *_cachedRep;
    NSImage *_cachedImage;
    int _frameWidth;
    int _frameHeight;
}
- (void)setFrameData:(NSData *)data width:(int)width height:(int)height;
@end

@implementation VideoRenderView

- (void)dealloc
{
    [_cachedImage release];
    [_cachedRep release];
    [super dealloc];
}

- (void)setFrameData:(NSData *)data width:(int)width height:(int)height
{
    if (width <= 0 || height <= 0 || !data || [data length] == 0) {
        return;
    }

    int bpr = width * 4;
    int expectedLen = bpr * height;
    if ((int)[data length] < expectedLen) {
        NSLog(@"[VideoRenderView] frame data too small: got %tu, expected %d",
              [data length], expectedLen);
        return;
    }

    // Recreate cached bitmap rep only when dimensions change
    if (!_cachedRep || _frameWidth != width || _frameHeight != height) {
        [_cachedImage release];
        _cachedImage = nil;
        [_cachedRep release];
        _cachedRep = nil;

        _cachedRep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:width
                          pixelsHigh:height
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:bpr
                        bitsPerPixel:32];
        if (!_cachedRep) {
            NSLog(@"[VideoRenderView] ERROR: failed to create NSBitmapImageRep %dx%d",
                  width, height);
            _frameWidth = 0;
            _frameHeight = 0;
            return;
        }

        _cachedImage = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
        [_cachedImage addRepresentation:_cachedRep];
    }

    // Copy frame data into the cached bitmap rep's backing buffer
    void *bmData = [_cachedRep bitmapData];
    if (!bmData) {
        NSLog(@"[VideoRenderView] ERROR: bitmapData is NULL for %dx%d rep", width, height);
        return;
    }
    memcpy(bmData, [data bytes], expectedLen);

    _frameWidth = width;
    _frameHeight = height;

    // Force immediate synchronous drawing — display triggers
    // drawRect: directly without waiting for the next run-loop iteration.
    [self display];
    [[self window] flushWindow];
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSLog(@"[VideoRenderView] drawRect: _frameWidth=%d _frameHeight=%d hasCachedImage=%d",
          _frameWidth, _frameHeight, (_cachedImage != nil));

    if (!_cachedImage) {
        [[NSColor blackColor] set];
        NSRectFill(self.bounds);
        return;
    }

    NSRect srcRect = NSMakeRect(0, 0, _frameWidth, _frameHeight);
    NSRect dstRect = self.bounds;

    // Aspect-preserving fit
    float srcAspect = (float)_frameWidth / (float)_frameHeight;
    float dstAspect = dstRect.size.width / MAX(dstRect.size.height, 1.0f);
    if (srcAspect > dstAspect) {
        float newH = dstRect.size.width / srcAspect;
        dstRect.origin.y += (dstRect.size.height - newH) * 0.5f;
        dstRect.size.height = newH;
    } else {
        float newW = dstRect.size.height * srcAspect;
        dstRect.origin.x += (dstRect.size.width - newW) * 0.5f;
        dstRect.size.width = newW;
    }

    // Letterbox background
    [[NSColor blackColor] set];
    NSRectFill(self.bounds);

    // Draw the cached frame
    [_cachedImage drawInRect:dstRect fromRect:srcRect
                   operation:NSCompositeSourceOver fraction:1.0];
}

@end

#pragma mark -

@implementation PlayerController

@synthesize mainWindow;
@synthesize videoView;
@synthesize flowView;
@synthesize playButton;
@synthesize stopButton;
@synthesize previousButton;
@synthesize nextButton;
@synthesize openButton;
@synthesize fullscreenButton;
@synthesize timeSlider;
@synthesize currentTimeLabel;
@synthesize totalTimeLabel;
@synthesize titleLabel;
@synthesize artistLabel;
@synthesize albumLabel;
@synthesize detailsLabel;
@synthesize progressIndicator;

#pragma mark - Init / Dealloc

- (id)init
{
    self = [super init];
    if (self) {
        playbackState = PlayerPlaybackStateStopped;
        currentFilePath = nil;
        avPlayer = nil;
        playerItem = nil;
        urlAsset = nil;
        audioPlayer = nil;
        playbackTimer = nil;
        overlayHideTimer = nil;
        overlayBar = nil;
        playlist = [[NSMutableArray alloc] init];
        coverImages = [[NSMutableDictionary alloc] init];
        currentIndex = -1;
        isVideo = NO;
        isFullscreen = NO;
        srandom((unsigned int)time(NULL));
        // Load persisted preferences via NSUserDefaults (GNUstep standard)
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        repeatEnabled = [defaults boolForKey:@"PlayerRepeatEnabled"];
        shuffleEnabled = [defaults boolForKey:@"PlayerShuffleEnabled"];
        coverAreaHeight = 200.0;
        playerMode = PlayerModeLocal;
        radioInitialized = NO;
        localVolume = 0.8;
        radioVolume = 0.8;
        // Restore persisted settings
        if ([defaults objectForKey:@"PlayerLocalVolume"]) {
            localVolume = [defaults floatForKey:@"PlayerLocalVolume"];
        }
        if ([defaults objectForKey:@"PlayerRadioVolume"]) {
            radioVolume = [defaults floatForKey:@"PlayerRadioVolume"];
        }
        if ([defaults objectForKey:@"PlayerMode"]) {
            playerMode = [defaults integerForKey:@"PlayerMode"];
        }

        // ---- yt-dlp / URL Streaming ---- //
        _ytdlpBackend = [[YTDLPBackend alloc] init];
        [_ytdlpBackend setDelegate:self];
        [_ytdlpBackend setYtdlpPath:[PreferencesController ytdlpPath]];
        _ytdlpAvailable = NO;
        _pendingStreamTitle = nil;
        _preferencesController = nil;  // created lazily when opening prefs
    }
    return self;
}

- (void)dealloc
{
    if (playbackTimer) {
        [playbackTimer invalidate];
        [playbackTimer release];
    }
    if (overlayHideTimer) {
        [overlayHideTimer invalidate];
        [overlayHideTimer release];
    }
    if (avPlayer) {
        [avPlayer pause];
        [avPlayer release];
    }
    if (playerItem) {
        [playerItem release];
    }
    if (urlAsset) {
        [urlAsset release];
    }
    if (audioPlayer) {
        [audioPlayer stop];
        [audioPlayer release];
    }
    [currentFilePath release];
    [playlist release];
    [coverImages release];
    [detailsLabel release];
    [overlayBar release];
    [searchField release];
    [statusLabel release];
    [radioTextLabel release];
    [volumeLabel release];
    [volumeSlider release];
    [muteCheckbox release];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(checkDebounce)
                                               object:nil];
    [_pendingRadioStation release];
    [_ytdlpBackend release];
    [_pendingStreamTitle release];
    [_preferencesController release];
    [super dealloc];
}

#pragma mark - Menu Creation

- (void)createMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];

    // ===== APPLICATION MENU =====
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"Player"
                                                        action:NULL
                                                 keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Player"];
    NSMenuItem *aboutItem = (NSMenuItem *)
        [appMenu addItemWithTitle:@"About Player"
                           action:@selector(orderFrontStandardAboutPanel:)
                    keyEquivalent:@""];
    [aboutItem setTarget:NSApp];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Preferences..."
                       action:@selector(openPreferences:)
                keyEquivalent:@","];
    [[appMenu itemAtIndex:[appMenu numberOfItems] - 1] setTarget:self];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Player"
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Hide Others"
                       action:@selector(hideOtherApplications:)
                keyEquivalent:@"h"];
    [[appMenu itemAtIndex:[appMenu numberOfItems] - 1]
        setKeyEquivalentModifierMask:NSAlternateKeyMask | NSCommandKeyMask];
    [appMenu addItemWithTitle:@"Show All"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Player"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];
    [appMenu release];
    [appMenuItem release];

    // ===== FILE MENU =====
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File"
                                                         action:NULL
                                                  keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *openItem = (NSMenuItem *)
        [fileMenu addItemWithTitle:@"Open File..."
                            action:@selector(openFile:)
                     keyEquivalent:@"o"];
    [openItem setTarget:self];
    NSMenuItem *openURLItem = (NSMenuItem *)
        [fileMenu addItemWithTitle:@"Open URL..."
                            action:@selector(openURL:)
                     keyEquivalent:@"U"];
    [openURLItem setTarget:self];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *closeItem = (NSMenuItem *)
        [fileMenu addItemWithTitle:@"Close Window"
                            action:@selector(performClose:)
                     keyEquivalent:@"w"];
    [closeItem setTarget:self];
    [fileMenuItem setSubmenu:fileMenu];
    [mainMenu addItem:fileMenuItem];
    [fileMenu release];
    [fileMenuItem release];

    // ===== EDIT MENU =====
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit"
                                                         action:NULL
                                                  keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo"
                        action:@selector(undo:)
                 keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo"
                        action:@selector(redo:)
                 keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut"
                        action:@selector(cut:)
                 keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy"
                        action:@selector(copy:)
                 keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste"
                        action:@selector(paste:)
                 keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All"
                        action:@selector(selectAll:)
                 keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];
    [mainMenu addItem:editMenuItem];
    [editMenu release];
    [editMenuItem release];

    // ===== PLAYBACK MENU =====
    NSMenuItem *playbackMenuItem = [[NSMenuItem alloc] initWithTitle:@"Playback"
                                                             action:NULL
                                                      keyEquivalent:@""];
    NSMenu *playbackMenu = [[NSMenu alloc] initWithTitle:@"Playback"];
    NSMenuItem *playPauseItem = (NSMenuItem *)
        [playbackMenu addItemWithTitle:@"Play / Pause"
                                action:@selector(playPause:)
                         keyEquivalent:@" "];
    [playPauseItem setTarget:self];
    NSMenuItem *stopItem = (NSMenuItem *)
        [playbackMenu addItemWithTitle:@"Stop"
                                action:@selector(stop:)
                         keyEquivalent:@"."];
    [stopItem setTarget:self];
    [stopItem setKeyEquivalentModifierMask:NSCommandKeyMask];
    [playbackMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *prevItem = (NSMenuItem *)
        [playbackMenu addItemWithTitle:@"Previous Track"
                                action:@selector(previousTrack:)
                         keyEquivalent:@","];
    [prevItem setTarget:self];
    [prevItem setKeyEquivalentModifierMask:NSCommandKeyMask];
    NSMenuItem *nextItem = (NSMenuItem *)
        [playbackMenu addItemWithTitle:@"Next Track"
                                action:@selector(nextTrack:)
                         keyEquivalent:@"."];
    [nextItem setTarget:self];
    [nextItem setKeyEquivalentModifierMask:NSCommandKeyMask];
    [playbackMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *repeatItem = [[NSMenuItem alloc] initWithTitle:@"Repeat"
                                                        action:@selector(toggleRepeat:)
                                                 keyEquivalent:@"R"];
    [repeatItem setTarget:self];
    [playbackMenu addItem:repeatItem];
    repeatMenuItem = repeatItem;
    [repeatItem release];
    [repeatMenuItem setState:repeatEnabled ? NSOnState : NSOffState];
    shuffleMenuItem = (NSMenuItem *)
        [playbackMenu addItemWithTitle:@"Shuffle"
                                action:@selector(toggleShuffle:)
                         keyEquivalent:@"s"];
    [shuffleMenuItem setTarget:self];
    [shuffleMenuItem setState:shuffleEnabled ? NSOnState : NSOffState];
    [playbackMenuItem setSubmenu:playbackMenu];
    [mainMenu addItem:playbackMenuItem];
    [playbackMenu release];
    [playbackMenuItem release];

    // ===== VIEW MENU =====
    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"View"
                                                         action:NULL
                                                  keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *fsItem = (NSMenuItem *)
        [viewMenu addItemWithTitle:@"Enter Fullscreen"
                            action:@selector(toggleFullscreen:)
                     keyEquivalent:@"f"];
    [fsItem setTarget:self];
    [viewMenuItem setSubmenu:viewMenu];
    [mainMenu addItem:viewMenuItem];
    [viewMenu release];
    [viewMenuItem release];

    // ===== RADIO MENU =====
    NSMenuItem *radioMenuItem = [[NSMenuItem alloc] initWithTitle:@"Radio"
                                                           action:NULL
                                                    keyEquivalent:@""];
    NSMenu *radioMenu = [[NSMenu alloc] initWithTitle:@"Radio"];

    // Browse Radio Stations — Cmd+R (Repeat moved to Cmd+Shift+R to avoid conflict)
    radioModeMenuItem = (NSMenuItem *)
        [radioMenu addItemWithTitle:@"Browse Radio Stations"
                             action:@selector(toggleRadioMode:)
                      keyEquivalent:@"r"];
    [radioModeMenuItem setTarget:self];
    [radioModeMenuItem setKeyEquivalentModifierMask:NSCommandKeyMask];

    // Open Radio Stream — Cmd+U
    [radioMenu addItemWithTitle:@"Open Radio Stream..."
                         action:@selector(openRadioStream:)
                  keyEquivalent:@"u"];
    [[radioMenu itemAtIndex:[radioMenu numberOfItems] - 1] setTarget:self];
    [[radioMenu itemAtIndex:[radioMenu numberOfItems] - 1]
        setKeyEquivalentModifierMask:NSCommandKeyMask];

    // Separator
    [radioMenu addItem:[NSMenuItem separatorItem]];

    // Stop Radio — Cmd+.
    [radioMenu addItemWithTitle:@"Stop Radio"
                         action:@selector(radioStop:)
                  keyEquivalent:@"."];
    [[radioMenu itemAtIndex:[radioMenu numberOfItems] - 1] setTarget:self];
    [[radioMenu itemAtIndex:[radioMenu numberOfItems] - 1]
        setKeyEquivalentModifierMask:NSCommandKeyMask];

    // Tagged separator for dynamic station list (rebuildRadioStationMenu adds items after this)
    NSMenuItem *stationSep = (NSMenuItem *)[NSMenuItem separatorItem];
    [stationSep setTag:9999];
    [radioMenu addItem:stationSep];

    // Let validateMenuItem: set checkmark dynamically (needed by Eau's _recursiveMenuUpdate:)
    [radioMenu setAutoenablesItems:YES];

    [radioMenuItem setSubmenu:radioMenu];
    [mainMenu addItem:radioMenuItem];
    [radioMenu release];
    [radioMenuItem release];

    [NSApp setMainMenu:mainMenu];
    [mainMenu release];
}

#pragma mark - UI Creation

- (void)createUI
{
    [self createMenu];

    CGFloat windowWidth = DEFAULT_WINDOW_WIDTH;
    CGFloat windowHeight = DEFAULT_WINDOW_HEIGHT;
    coverAreaHeight = floorf(windowHeight * COVER_AREA_FRACTION);

    NSRect windowFrame = NSMakeRect(100, 100, windowWidth, windowHeight);
    mainWindow = [[NSWindow alloc] initWithContentRect:windowFrame
                                             styleMask:NSTitledWindowMask |
                                                       NSClosableWindowMask |
                                                       NSMiniaturizableWindowMask |
                                                       NSResizableWindowMask
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    [mainWindow setTitle:@"Player"];
    [mainWindow setDelegate:self];
    [mainWindow setMinSize:NSMakeSize(PLAYER_CONTENT_MIN_WIDTH, PLAYER_CONTENT_MIN_HEIGHT)];
    [mainWindow setAcceptsMouseMovedEvents:YES];
    [mainWindow setContentMinSize:NSMakeSize(PLAYER_CONTENT_MIN_WIDTH, PLAYER_CONTENT_MIN_HEIGHT)];

    // Replace the default content view with a drop-target view for drag-and-drop
    DropTargetView *dropView = [[DropTargetView alloc]
        initWithFrame:[[mainWindow contentView] frame]
           controller:self];
    [mainWindow setContentView:dropView];
    [dropView release];
    NSView *contentView = [mainWindow contentView];

    // ===== ITEM FLOW (COVER ART CAROUSEL) =====
    // Fills top portion, stretches horizontally and vertically
    NSRect coverFrame = NSMakeRect(0, 0, windowWidth, coverAreaHeight);
    flowView = [[ItemFlowView alloc] initWithFrame:coverFrame];
    [flowView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [flowView setDataSource:self];
    [flowView setDelegate:self];
    [contentView addSubview:flowView];

    // Video view (identical frame, hidden until video content)
    videoView = [[NSView alloc] initWithFrame:coverFrame];
    [videoView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [videoView setHidden:YES];
    [contentView addSubview:videoView];

    // Image view inside videoView for decoded video frames
    _videoRenderView = [[VideoRenderView alloc] initWithFrame:[videoView bounds]];
    [_videoRenderView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [videoView addSubview:_videoRenderView];
    [_videoRenderView release]; // retained by videoView subview

    // Progress spinner (centered on the cover area)
    NSRect progressFrame = NSMakeRect(0, 0, 24, 24);
    progressIndicator = [[NSProgressIndicator alloc] initWithFrame:progressFrame];
    [progressIndicator setStyle:NSProgressIndicatorSpinningStyle];
    [progressIndicator setHidden:YES];
    [progressIndicator setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin |
                                           NSViewMinYMargin | NSViewMaxYMargin];
    [contentView addSubview:progressIndicator];

    // ===== TIME SLIDER ROW =====
    // Placed just below the cover area; stretches horizontally.
    // We'll position everything in layoutSubviews so we just add as subviews here.
    currentTimeLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [currentTimeLabel setStringValue:@"0:00"];
    [currentTimeLabel setEditable:NO];
    [currentTimeLabel setSelectable:NO];
    [currentTimeLabel setBezeled:NO];
    [currentTimeLabel setDrawsBackground:NO];
    [currentTimeLabel setAlignment:NSRightTextAlignment];
    [currentTimeLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [contentView addSubview:currentTimeLabel];

    timeSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    [timeSlider setMinValue:0.0];
    [timeSlider setMaxValue:100.0];
    [timeSlider setDoubleValue:0.0];
    [timeSlider setContinuous:YES];
    [timeSlider setTarget:self];
    [timeSlider setAction:@selector(seekToTime:)];
    [contentView addSubview:timeSlider];

    totalTimeLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [totalTimeLabel setStringValue:@"0:00"];
    [totalTimeLabel setEditable:NO];
    [totalTimeLabel setSelectable:NO];
    [totalTimeLabel setBezeled:NO];
    [totalTimeLabel setDrawsBackground:NO];
    [totalTimeLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [contentView addSubview:totalTimeLabel];

    // ===== PLAYBACK CONTROLS ROW =====
    // Centered in the window, fixed size
    previousButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [previousButton setImage:[self iconPrevious]];
    [previousButton setImagePosition:NSImageOnly];
    [previousButton setButtonType:NSMomentaryLight];
    [previousButton setTarget:self];
    [previousButton setAction:@selector(previousTrack:)];
    [previousButton setEnabled:NO];
    [contentView addSubview:previousButton];

    playButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [playButton setImage:[self iconPlay]];
    [playButton setAlternateImage:[self iconPause]];
    [playButton setImagePosition:NSImageOnly];
    [playButton setButtonType:NSMomentaryLight];
    [playButton setTarget:self];
    [playButton setAction:@selector(playPause:)];
    [playButton setEnabled:NO];
    [contentView addSubview:playButton];

    stopButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [stopButton setImage:[self iconStop]];
    [stopButton setImagePosition:NSImageOnly];
    [stopButton setButtonType:NSMomentaryLight];
    [stopButton setTarget:self];
    [stopButton setAction:@selector(stop:)];
    [stopButton setEnabled:NO];
    [contentView addSubview:stopButton];

    nextButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [nextButton setImage:[self iconNext]];
    [nextButton setImagePosition:NSImageOnly];
    [nextButton setButtonType:NSMomentaryLight];
    [nextButton setTarget:self];
    [nextButton setAction:@selector(nextTrack:)];
    [nextButton setEnabled:NO];
    [contentView addSubview:nextButton];

    // ===== BOTTOM CONTROLS ROW =====
    openButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [openButton setTitle:@"Open..."];
    [openButton setButtonType:NSMomentaryLight];
    [openButton setTarget:self];
    [openButton setAction:@selector(openFile:)];
    [contentView addSubview:openButton];

    fullscreenButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [fullscreenButton setImage:[self iconFullscreen]];
    [fullscreenButton setImagePosition:NSImageOnly];
    [fullscreenButton setButtonType:NSMomentaryLight];
    [fullscreenButton setTarget:self];
    [fullscreenButton setAction:@selector(toggleFullscreen:)];
    [contentView addSubview:fullscreenButton];

    // ===== METADATA LABELS =====
    titleLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [titleLabel setStringValue:@"No file loaded"];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setFont:METRICS_FONT_SYSTEM_BOLD_13];
    [contentView addSubview:titleLabel];

    artistLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [artistLabel setStringValue:@""];
    [artistLabel setEditable:NO];
    [artistLabel setSelectable:NO];
    [artistLabel setBezeled:NO];
    [artistLabel setDrawsBackground:NO];
    [artistLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [contentView addSubview:artistLabel];

    albumLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [albumLabel setStringValue:@""];
    [albumLabel setEditable:NO];
    [albumLabel setSelectable:NO];
    [albumLabel setBezeled:NO];
    [albumLabel setDrawsBackground:NO];
    [albumLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [contentView addSubview:albumLabel];

    detailsLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [detailsLabel setStringValue:@""];
    [detailsLabel setEditable:NO];
    [detailsLabel setSelectable:NO];
    [detailsLabel setBezeled:NO];
    [detailsLabel setDrawsBackground:NO];
    [detailsLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [contentView addSubview:detailsLabel];

    // ===== RADIO MODE UI ELEMENTS (hidden initially) =====
    BOOL themeSearch = [NSSearchFieldCell instancesRespondToSelector:@selector(EAUsearchButtonRectForBounds:)];
    if (themeSearch)
      {
        searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
      }
    else
      {
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        [tf setBezeled:YES];
        [tf setBezelStyle:NSTextFieldRoundedBezel];
        [tf setEditable:YES];
        [tf setSelectable:YES];
        searchField = tf;
      }
    [[searchField cell] setPlaceholderString:@"Search Radio Stations..."];
    [searchField setTarget:self];
    [searchField setAction:@selector(radioSearchAction:)];
    [searchField setHidden:YES];
    [contentView addSubview:searchField];

    statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [statusLabel setStringValue:@""];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setAlignment:NSTextAlignmentCenter];
    [statusLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [statusLabel setHidden:YES];
    [contentView addSubview:statusLabel];

    radioTextLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [radioTextLabel setStringValue:@""];
    [radioTextLabel setEditable:NO];
    [radioTextLabel setSelectable:NO];
    [radioTextLabel setBezeled:NO];
    [radioTextLabel setDrawsBackground:NO];
    [radioTextLabel setAlignment:NSTextAlignmentCenter];
    [radioTextLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [[radioTextLabel cell] setLineBreakMode:NSLineBreakByWordWrapping];
    [radioTextLabel setHidden:YES];
    [contentView addSubview:radioTextLabel];

    volumeLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [volumeLabel setStringValue:@"Volume:"];
    [volumeLabel setEditable:NO];
    [volumeLabel setSelectable:NO];
    [volumeLabel setBezeled:NO];
    [volumeLabel setDrawsBackground:NO];
    [volumeLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [volumeLabel setHidden:YES];
    [contentView addSubview:volumeLabel];

    volumeSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    [volumeSlider setMinValue:0.0];
    [volumeSlider setMaxValue:1.0];
    [volumeSlider setDoubleValue:localVolume];
    [volumeSlider setContinuous:YES];
    [volumeSlider setTarget:self];
    [volumeSlider setAction:@selector(radioVolumeChanged:)];
    [volumeSlider setHidden:YES];
    [contentView addSubview:volumeSlider];

    muteCheckbox = [[NSButton alloc] initWithFrame:NSZeroRect];
    [muteCheckbox setButtonType:NSSwitchButton];
    [muteCheckbox setTitle:@"Mute"];
    [muteCheckbox setTarget:self];
    [muteCheckbox setAction:@selector(radioMuteToggled:)];
    [muteCheckbox setHidden:YES];
    [contentView addSubview:muteCheckbox];

    // Initial layout
    [self layoutSubviews];
}

#pragma mark - Button Icons

- (NSImage *)createIconWithBlock:(void(^)(void))drawBlock size:(NSSize)size
{
    NSImage *img = [[NSImage alloc] initWithSize:size];
    [img lockFocus];
    // Scale the icon content to 60 % centered within the image rect
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:size.width / 2.0 yBy:size.height / 2.0];
    [t scaleBy:0.6];
    [t translateXBy:-size.width / 2.0 yBy:-size.height / 2.0];
    [t concat];

    [[NSColor controlTextColor] set];
    drawBlock();
    [img unlockFocus];
    return [img autorelease];
}

- (NSImage *)iconPrevious
{
    return [self createIconWithBlock:^{
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p setLineJoinStyle:NSRoundLineJoinStyle];
        // Vertical bar on left
        [p appendBezierPathWithRect:NSMakeRect(1, 1, 3, 14)];
        // Triangle pointing left
        [p moveToPoint:NSMakePoint(17, 1)];
        [p lineToPoint:NSMakePoint(6, 8)];
        [p lineToPoint:NSMakePoint(17, 15)];
        [p closePath];
        [p fill];
    } size:NSMakeSize(18, 16)];
}

- (NSImage *)iconPlay
{
    return [self createIconWithBlock:^{
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p setLineJoinStyle:NSRoundLineJoinStyle];
        [p moveToPoint:NSMakePoint(3, 1)];
        [p lineToPoint:NSMakePoint(15, 8)];
        [p lineToPoint:NSMakePoint(3, 15)];
        [p closePath];
        [p fill];
    } size:NSMakeSize(18, 16)];
}

- (NSImage *)iconPause
{
    return [self createIconWithBlock:^{
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p appendBezierPathWithRect:NSMakeRect(2, 1, 5, 14)];
        [p appendBezierPathWithRect:NSMakeRect(11, 1, 5, 14)];
        [p fill];
    } size:NSMakeSize(18, 16)];
}

- (NSImage *)iconStop
{
    return [self createIconWithBlock:^{
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p setLineJoinStyle:NSRoundLineJoinStyle];
        [p appendBezierPathWithRect:NSMakeRect(2, 2, 14, 12)];
        [p fill];
    } size:NSMakeSize(18, 16)];
}

- (NSImage *)iconNext
{
    return [self createIconWithBlock:^{
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p setLineJoinStyle:NSRoundLineJoinStyle];
        // Triangle pointing right
        [p moveToPoint:NSMakePoint(1, 1)];
        [p lineToPoint:NSMakePoint(12, 8)];
        [p lineToPoint:NSMakePoint(1, 15)];
        [p closePath];
        // Vertical bar on right
        [p appendBezierPathWithRect:NSMakeRect(14, 1, 3, 14)];
        [p fill];
    } size:NSMakeSize(18, 16)];
}

- (NSImage *)iconFullscreen
{
    return [self createIconWithBlock:^{
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p setLineWidth:1.6];
        [p setLineCapStyle:NSRoundLineCapStyle];
        [p setLineJoinStyle:NSRoundLineJoinStyle];
        // Top-left: arrow from interior pointing up-left
        [p moveToPoint:NSMakePoint(10, 10)];
        [p lineToPoint:NSMakePoint(2, 2)];
        [p moveToPoint:NSMakePoint(2, 8)];
        [p lineToPoint:NSMakePoint(2, 2)];
        [p lineToPoint:NSMakePoint(8, 2)];
        // Bottom-right: arrow from interior pointing down-right
        [p moveToPoint:NSMakePoint(6, 6)];
        [p lineToPoint:NSMakePoint(14, 14)];
        [p moveToPoint:NSMakePoint(14, 8)];
        [p lineToPoint:NSMakePoint(14, 14)];
        [p lineToPoint:NSMakePoint(8, 14)];
        [p stroke];
    } size:NSMakeSize(16, 16)];
}

#pragma mark - Layout Engine

- (void)layoutSubviews
{
    if (isFullscreen) {
        [self layoutFullscreenMode];
    } else {
        [self layoutNormalMode];
    }
}

- (void)layoutNormalMode
{
    // In radio mode, use a completely different layout
    if (playerMode == PlayerModeRadio) {
        [self layoutRadioMode];
        return;
    }

    NSView *content = [mainWindow contentView];
    NSRect bounds = [content bounds];
    CGFloat W = bounds.size.width;
    CGFloat H = bounds.size.height;
    CGFloat margin = METRICS_CONTENT_SIDE_MARGIN;

    // Restore controls that might be hidden from fullscreen
    [currentTimeLabel setHidden:NO];
    [timeSlider setHidden:NO];
    [totalTimeLabel setHidden:NO];
    [previousButton setHidden:NO];
    [playButton setHidden:NO];
    [stopButton setHidden:NO];
    [nextButton setHidden:NO];
    [openButton setHidden:NO];
    [fullscreenButton setHidden:NO];
    [titleLabel setHidden:NO];
    [artistLabel setHidden:NO];
    [albumLabel setHidden:NO];
    [detailsLabel setHidden:NO];
    [volumeLabel setHidden:NO];
    [volumeSlider setHidden:NO];
    [muteCheckbox setHidden:NO];

    // ---- Cover / video area (COVER_AREA_FRACTION) ----
    coverAreaHeight = MAX(120.0, floorf(H * COVER_AREA_FRACTION));
    CGFloat coverBottom = H - coverAreaHeight;
    NSRect coverFrame = NSMakeRect(0, coverBottom, W, coverAreaHeight);
    [flowView setFrame:coverFrame];
    [videoView setFrame:coverFrame];

    // Center spinner on cover area
    NSSize spinSize = [progressIndicator frame].size;
    [progressIndicator setFrameOrigin:NSMakePoint(
        NSMidX(coverFrame) - spinSize.width / 2.0,
        NSMidY(coverFrame) - spinSize.height / 2.0)];

    // ---- Build content below cover from bottom up ----
    // Content heights
    CGFloat lineH = 15.0;
    CGFloat lineGap = 1.0;
    CGFloat metaH = 4 * lineH + 3 * lineGap;   // ~~63
    CGFloat sliderRowH = 16.0;
    CGFloat ctrlH = CONTROL_BAR_HEIGHT;         // 22
    CGFloat volH = 22.0;
    CGFloat bottomH = METRICS_BUTTON_HEIGHT;    // 20

    // Vertical gaps between sections, using AppearanceMetrics spacing
    CGFloat gapMeta  = METRICS_SPACE_12;   // cover → metadata
    CGFloat gapTimer = METRICS_SPACE_8;    // metadata → time slider
    CGFloat gapCtrl  = METRICS_SPACE_12;   // time slider → playback buttons
    CGFloat gapVol   = METRICS_SPACE_12;   // playback buttons → volume
    CGFloat gapBot   = METRICS_SPACE_12;   // volume → bottom buttons

    CGFloat neededBelow = gapMeta + metaH + gapTimer + sliderRowH + gapCtrl
                          + ctrlH + gapVol + volH + gapBot + bottomH
                          + METRICS_CONTENT_BOTTOM_MARGIN;

    CGFloat availableBelow = coverBottom;
    CGFloat extraSpace = availableBelow - neededBelow;
    if (extraSpace < 0) extraSpace = 0;

    // Start at bottom margin, ascend
    CGFloat by = METRICS_CONTENT_BOTTOM_MARGIN + floorf(extraSpace * 0.15f);

    // ---- Bottom row: Open, Fullscreen ----
    CGFloat openW = 68.0;
    CGFloat fsBtnW = 28.0;
    [openButton setFrame:NSMakeRect(margin, by, openW, bottomH)];
    [openButton setAutoresizingMask:NSViewMaxXMargin];

    CGFloat rightEdge = W - margin;
    [fullscreenButton setFrame:NSMakeRect(rightEdge - fsBtnW, by, fsBtnW, bottomH)];
    [fullscreenButton setAutoresizingMask:NSViewMinXMargin];
    by += bottomH + gapBot;

    // ---- Volume slider row ----
    CGFloat volLabelW = 55.0;
    CGFloat maxVolSlider = W - margin - (margin + volLabelW + METRICS_SPACE_8 + 68 + METRICS_SPACE_8);
    CGFloat volSliderW = MIN(180.0, maxVolSlider);
    CGFloat muteW = 60.0;

    [volumeLabel setFrame:NSMakeRect(margin, by, volLabelW, volH)];
    [volumeSlider setFrame:NSMakeRect(margin + volLabelW + METRICS_SPACE_8, by, volSliderW, volH)];
    [volumeSlider setAutoresizingMask:NSViewWidthSizable];
    [muteCheckbox setFrame:NSMakeRect(NSMaxX([volumeSlider frame]) + METRICS_SPACE_8, by + 2, muteW, 18)];
    by += volH + gapVol;

    // ---- Playback controls row (centered) ----
    CGFloat btnW = 36.0;
    CGFloat btnH = ctrlH;
    CGFloat gap = 6.0;
    CGFloat fourBtnW = 4 * btnW + 3 * gap;
    CGFloat ctrlStartX = floorf((W - fourBtnW) / 2.0);

    [previousButton setFrame:NSMakeRect(ctrlStartX, by, btnW, btnH)];
    [playButton setFrame:NSMakeRect(ctrlStartX + btnW + gap, by, btnW, btnH)];
    [stopButton setFrame:NSMakeRect(ctrlStartX + 2 * (btnW + gap), by, btnW, btnH)];
    [nextButton setFrame:NSMakeRect(ctrlStartX + 3 * (btnW + gap), by, btnW, btnH)];
    by += btnH + gapCtrl;

    // ---- Time slider row ----
    CGFloat timeLabelW = 42.0;
    CGFloat sliderW = W - 2 * margin - 2 * timeLabelW - METRICS_SPACE_8;

    [currentTimeLabel setFrame:NSMakeRect(margin, by, timeLabelW, sliderRowH)];
    [currentTimeLabel setAutoresizingMask:NSViewMaxXMargin];

    [timeSlider setFrame:NSMakeRect(margin + timeLabelW + 4, by, sliderW, sliderRowH)];
    [timeSlider setAutoresizingMask:NSViewWidthSizable];

    [totalTimeLabel setFrame:NSMakeRect(margin + timeLabelW + 4 + sliderW + 4, by, timeLabelW, sliderRowH)];
    [totalTimeLabel setAutoresizingMask:NSViewMinXMargin];
    by += sliderRowH + gapTimer;

    // ---- Metadata labels ----
    CGFloat metaW = W - 2 * margin;
    [titleLabel setFrame:NSMakeRect(margin, by, metaW, lineH)];
    [titleLabel setAutoresizingMask:NSViewWidthSizable];
    by += lineH + lineGap;

    [artistLabel setFrame:NSMakeRect(margin, by, metaW, lineH)];
    [artistLabel setAutoresizingMask:NSViewWidthSizable];
    by += lineH + lineGap;

    [albumLabel setFrame:NSMakeRect(margin, by, metaW, lineH)];
    [albumLabel setAutoresizingMask:NSViewWidthSizable];
    by += lineH + lineGap;

    [detailsLabel setFrame:NSMakeRect(margin, by, metaW, lineH)];
    [detailsLabel setAutoresizingMask:NSViewWidthSizable];

    // Hide overlay if in normal mode
    if (overlayBar && ![overlayBar isHidden]) {
        [overlayBar setHidden:YES];
    }
}

- (void)layoutFullscreenMode
{
    NSView *content = [mainWindow contentView];
    NSRect bounds = [content bounds];
    CGFloat W = bounds.size.width;
    CGFloat H = bounds.size.height;

    // Cover art fills entire screen
    NSRect fullFrame = NSMakeRect(0, 0, W, H);
    [flowView setFrame:fullFrame];
    [flowView setNeedsDisplay:YES];
    [videoView setFrame:fullFrame];
    [videoView setNeedsDisplay:YES];

    // Center spinner
    NSSize spinSize = [progressIndicator frame].size;
    [progressIndicator setFrameOrigin:NSMakePoint(
        NSMidX(fullFrame) - spinSize.width / 2.0,
        NSMidY(fullFrame) - spinSize.height / 2.0)];

    // Hide all normal controls (they live in the overlay bar now)
    [currentTimeLabel setHidden:YES];
    [timeSlider setHidden:YES];
    [totalTimeLabel setHidden:YES];
    [previousButton setHidden:YES];
    [playButton setHidden:YES];
    [stopButton setHidden:YES];
    [nextButton setHidden:YES];
    [openButton setHidden:YES];
    [fullscreenButton setHidden:YES];
    [titleLabel setHidden:YES];
    [artistLabel setHidden:YES];
    [albumLabel setHidden:YES];
    [detailsLabel setHidden:YES];
    [radioTextLabel setHidden:YES];

    // Create overlay bar if needed
    if (!overlayBar) {
        overlayBar = [[NSView alloc] initWithFrame:NSZeroRect];
        [overlayBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
        [overlayBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
        [content addSubview:overlayBar];
    }
    [overlayBar setHidden:NO];

    // Layout overlay bar at bottom
    CGFloat barH = OVERLAY_BAR_HEIGHT;
    CGFloat barY = 0;
    CGFloat barW = W;
    [overlayBar setFrame:NSMakeRect(0, barY, barW, barH)];

    // Fullscreen button in overlay bar (right side)
    CGFloat fsBtnW = 28.0;
    CGFloat margin = 16.0;
    [fullscreenButton setHidden:NO];
    [fullscreenButton setFrame:NSMakeRect(barW - fsBtnW - margin,
                                           (barH - CONTROL_BAR_HEIGHT) / 2.0,
                                           fsBtnW, CONTROL_BAR_HEIGHT)];

    // Play/Pause centered
    CGFloat btnW = 36.0;
    CGFloat gap = 8.0;
    CGFloat centerX = floorf(W / 2.0);
    CGFloat btnStartX = centerX - (4 * btnW + 3 * gap) / 2.0;

    [previousButton setHidden:NO];
    [previousButton setFrame:NSMakeRect(btnStartX, (barH - CONTROL_BAR_HEIGHT) / 2.0,
                                         btnW, CONTROL_BAR_HEIGHT)];

    [playButton setHidden:NO];
    [playButton setFrame:NSMakeRect(btnStartX + btnW + gap,
                                     (barH - CONTROL_BAR_HEIGHT) / 2.0,
                                     btnW, CONTROL_BAR_HEIGHT)];

    [stopButton setHidden:NO];
    [stopButton setFrame:NSMakeRect(btnStartX + 2 * (btnW + gap),
                                    (barH - CONTROL_BAR_HEIGHT) / 2.0,
                                    btnW, CONTROL_BAR_HEIGHT)];

    [nextButton setHidden:NO];
    [nextButton setFrame:NSMakeRect(btnStartX + 3 * (btnW + gap),
                                    (barH - CONTROL_BAR_HEIGHT) / 2.0,
                                    btnW, CONTROL_BAR_HEIGHT)];

    // Time slider above the buttons in the bar
    CGFloat sliderBarMargin = 60.0;
    CGFloat timeLabelW = 40.0;
    CGFloat sliderW = barW - 2 * sliderBarMargin - 2 * timeLabelW - 2 * 4;
    [currentTimeLabel setHidden:NO];
    [currentTimeLabel setFrame:NSMakeRect(sliderBarMargin,
                                          barH - 14 - 4, timeLabelW, 14)];
    [timeSlider setHidden:NO];
    [timeSlider setFrame:NSMakeRect(sliderBarMargin + timeLabelW + 4,
                                    barH - 16 - 2, sliderW, 16)];
    [totalTimeLabel setHidden:NO];
    [totalTimeLabel setFrame:NSMakeRect(sliderBarMargin + timeLabelW + 4 + sliderW + 4,
                                        barH - 14 - 4, timeLabelW, 14)];

    // Mouse tracking for auto-hide of overlay
    [self showOverlay];
}

#pragma mark - Fullscreen

- (IBAction)toggleFullscreen:(id)sender
{
    if (isFullscreen) {
        [self exitFullscreen];
    } else {
        [self enterFullscreen];
    }
}

- (void)enterFullscreen
{
    if (isFullscreen) return;
    isFullscreen = YES;

    // In GNUstep we cannot dynamically change the window styleMask,
    // so we achieve fullscreen by raising the window level and
    // resizing to fill the screen.
    [mainWindow setLevel:NSScreenSaverWindowLevel];

    // Store normal frame and resize to fill screen
    NSRect screenFrame = [[NSScreen mainScreen] frame];
    [mainWindow setFrame:screenFrame display:YES animate:NO];

    // Update menu item title and bind Escape key
    [[[[[NSApp mainMenu] itemWithTitle:@"View"] submenu] itemWithTitle:@"Enter Fullscreen"]
        setTitle:@"Exit Fullscreen"];
    [[[[[NSApp mainMenu] itemWithTitle:@"View"] submenu] itemWithTitle:@"Exit Fullscreen"]
        setKeyEquivalent:@"\e"];

    [self layoutSubviews];
    [self showOverlay];
    [self scheduleOverlayHide];
}

- (void)exitFullscreen
{
    if (!isFullscreen) return;
    isFullscreen = NO;

    // Restore window level
    [mainWindow setLevel:NSNormalWindowLevel];

    // Restore normal size
    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    CGFloat w = DEFAULT_WINDOW_WIDTH;
    CGFloat h = DEFAULT_WINDOW_HEIGHT;
    NSRect frame = NSMakeRect(
        NSMidX(screenFrame) - w / 2.0,
        NSMidY(screenFrame) - h / 2.0,
        w, h);
    [mainWindow setFrame:frame display:YES animate:NO];

    // Restore menu title and clear Escape key
    [[[[[NSApp mainMenu] itemWithTitle:@"View"] submenu] itemWithTitle:@"Exit Fullscreen"]
        setTitle:@"Enter Fullscreen"];
    [[[[[NSApp mainMenu] itemWithTitle:@"View"] submenu] itemWithTitle:@"Enter Fullscreen"]
        setKeyEquivalent:@""];

    // Cancel overlay hide timer
    if (overlayHideTimer) {
        [overlayHideTimer invalidate];
        [overlayHideTimer release];
        overlayHideTimer = nil;
    }
    // Hide overlay bar
    if (overlayBar) {
        [overlayBar setHidden:YES];
    }

    [self layoutSubviews];
}

#pragma mark - Overlay Controls (Fullscreen)

- (void)showOverlay
{
    if (!isFullscreen) return;
    if (overlayBar) {
        [overlayBar setAlphaValue:1.0];
        [overlayBar setHidden:NO];
    }
}

- (void)hideOverlay
{
    if (!isFullscreen) return;
    if (overlayBar) {
        [overlayBar setAlphaValue:0.0];
        [overlayBar setHidden:YES];
    }
}

- (void)scheduleOverlayHide
{
    if (overlayHideTimer) {
        [overlayHideTimer invalidate];
        [overlayHideTimer release];
    }
    overlayHideTimer = [[NSTimer scheduledTimerWithTimeInterval:OVERLAY_HIDE_DELAY
                                                         target:self
                                                       selector:@selector(overlayAutoHideTimerFired:)
                                                       userInfo:nil
                                                        repeats:NO] retain];
}

- (void)overlayAutoHideTimerFired:(NSTimer *)timer
{
    [self hideOverlay];
    overlayHideTimer = nil;
}

- (void)mouseMoved:(NSEvent *)event
{
    if (!isFullscreen) return;

    NSPoint loc = [event locationInWindow];

    // Show overlay when mouse is in the bottom 80px
    if (loc.y < 80.0) {
        [self showOverlay];
        [self scheduleOverlayHide];
    }
}

#pragma mark - Window Delegate

- (void)windowDidResize:(NSNotification *)notification
{
    [self layoutSubviews];
}

- (BOOL)windowShouldClose:(id)sender
{
    [NSApp terminate:self];
    return YES;
}

#pragma mark - Application Delegate

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    if (menuItem == radioModeMenuItem) {
        NSString *correctTitle = (playerMode == PlayerModeRadio)
            ? @"Exit Radio Mode" : @"Browse Radio Stations";
        if (![[menuItem title] isEqualToString:correctTitle]) {
            [menuItem setTitle:correctTitle];
        }
    }
    // Set checkmark on the currently playing (or pending) radio station
    RadioStation *station = [menuItem representedObject];
    if ([station isKindOfClass:[RadioStation class]]) {
        RadioManager *rm = [RadioManager sharedManager];
        NSString *currentName = [rm currentStationName] ?: [_pendingRadioStation name];
        if (currentName && [[station name] isEqualToString:currentName]) {
            [menuItem setState:NSOnState];
        } else {
            [menuItem setState:NSOffState];
        }
    }
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSArray *arguments = [[NSProcessInfo processInfo] arguments];

    [NSApp setDelegate:self];

    [self createUI];

    // Restore persisted volume slider for the current mode
    [volumeSlider setDoubleValue:(playerMode == PlayerModeRadio) ? radioVolume : localVolume];

    // Restore persisted radio mode — reset guard so enterRadioMode runs
    if (playerMode == PlayerModeRadio) {
        playerMode = PlayerModeLocal;
        [self enterRadioMode];
    }

    if ([arguments count] > 1) {
        [self handleCommandLineArguments];
        return;
    }

    if (mainWindow) {
        [mainWindow makeKeyAndOrderFront:self];
    }
    // Check yt-dlp availability on startup
    [self checkYTDLPAvailability];
    if (_ytdlpAvailable) {
        NSLog( @"[Player] yt-dlp is available for URL resolution");
    } else {
        NSLog(@"[Player] yt-dlp not found - URL resolution disabled");
    }

    [self updateStatus:@"Ready — open a media file to start playing"];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    if (playbackTimer) {
        [playbackTimer invalidate];
        [playbackTimer release];
        playbackTimer = nil;
    }
    if (_fadeTimer) {
        [_fadeTimer invalidate];
        [_fadeTimer release];
        _fadeTimer = nil;
    }
    if (overlayHideTimer) {
        [overlayHideTimer invalidate];
        [overlayHideTimer release];
        overlayHideTimer = nil;
    }
    if (avPlayer) {
        [avPlayer pause];
    }
    if (audioPlayer) {
        [audioPlayer stop];
    }
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    // Second pass: the fade is done, let the app die
    if (_quittingAfterFade) {
        return NSTerminateNow;
    }

    NSLog(@"[Player] applicationShouldTerminate: checking for running sound");

    BOOL streamPlaying = [[StreamPlayer sharedPlayer] isPlaying];
    BOOL avPlaying = (avPlayer != nil && [avPlayer rate] > 0.0f);
    BOOL audioPlaying = (audioPlayer != nil && [audioPlayer isPlaying]);
    if (!streamPlaying && !avPlaying && !audioPlaying) {
        return NSTerminateNow;
    }

    // Hide the windows first so the app is out of sight while the
    // sound fades away behind the scenes.
    [[NSApp windows] makeObjectsPerformSelector:@selector(orderOut:) withObject:nil];

    _fadeStartStreamVolume = [[StreamPlayer sharedPlayer] volume];
    _fadeStartAudioVolume = (audioPlayer != nil) ? [audioPlayer volume] : 0.0f;
    [_fadeStartDate release];
    _fadeStartDate = [[NSDate alloc] init];

    _fadeTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                  target:self
                                                selector:@selector(fadeOutTick:)
                                                userInfo:nil
                                                 repeats:YES];

    return NSTerminateLater;
}

- (void)fadeOutTick:(NSTimer *)timer
{
    static const NSTimeInterval fadeDuration = 1.0;

    NSTimeInterval elapsed = -[_fadeStartDate timeIntervalSinceNow];
    CGFloat t = elapsed / fadeDuration;
    if (t > 1.0) {
        t = 1.0;
    }

    // Smoothstep easing so the fade starts and ends gently
    CGFloat eased = t * t * (3.0 - 2.0 * t);
    float remaining = 1.0f - (float)eased;

    [[StreamPlayer sharedPlayer] setVolume:_fadeStartStreamVolume * remaining];
    if (audioPlayer != nil) {
        [audioPlayer setVolume:_fadeStartAudioVolume * remaining];
    }

    if (t >= 1.0) {
        NSLog(@"[Player] fade-out done, terminating");
        [_fadeTimer invalidate];
        [_fadeTimer release];
        _fadeTimer = nil;
        [_fadeStartDate release];
        _fadeStartDate = nil;
        [[StreamPlayer sharedPlayer] setVolume:0.0f];
        _quittingAfterFade = YES;
        [NSApp replyToApplicationShouldTerminate:YES];
    }
}

- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename
{
    [self loadFile:filename];
    return YES;
}

#pragma mark - Playback Actions

- (IBAction)openFile:(id)sender
{
    [self showOpenPanel];
}

- (IBAction)openURL:(id)sender
{
    NSLog(@"[Player] >>> openURL: CALLED (sender=%@)", sender);
    // Only offer yt-dlp resolution if it's available
    if (!_ytdlpAvailable) {
        [self checkYTDLPAvailability];
        if (!_ytdlpAvailable) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"yt-dlp Not Available"];
            [alert setInformativeText:@"To open streaming URLs from sites like YouTube, "
                @"you need yt-dlp installed.\n\n"
                @"Install it with your package manager (e.g., 'apt install yt-dlp' "
                @"or 'brew install yt-dlp'), then set the path in Preferences."];
            [alert addButtonWithTitle:@"Open Preferences"];
            [alert addButtonWithTitle:@"Cancel"];
            NSInteger result = [alert runModal];
            [alert release];
            if (result == NSAlertFirstButtonReturn) {
                [self openPreferences:sender];
            }
            return;
        }
    }

    // Prompt for URL
    NSString *urlString = [self _inputDialogWithTitle:@"Open URL"
                                              message:@"Enter a URL from YouTube, SoundCloud, Vimeo, or other streaming site."
                                          placeholder:@"https://www.youtube.com/watch?v=..."];

    NSLog(@"[Player] openURL - user entered: %@", urlString);

    if ([urlString length] > 0) {
        // If it looks like a local file or direct stream URL, play it directly
        if ([urlString hasPrefix:@"http://"] || [urlString hasPrefix:@"https://"]) {
            // Check if it looks like a direct stream URL (common patterns)
            BOOL isDirectStream = NO;
            NSArray *directExtensions = @[@".mp3", @".wav", @".ogg", @".flac",
                                           @".m4a", @".aac", @".mp4", @".m3u8",
                                           @".pls", @".asx", @".xspf"];
            NSString *lower = [urlString lowercaseString];
            for (NSString *ext in directExtensions) {
                if ([lower hasSuffix:ext]) {
                    isDirectStream = YES;
                    break;
                }
            }

            if (isDirectStream) {
                NSLog(@"[Player] openURL - detected direct stream URL, playing directly");
                // Play directly
                [self playStreamURL:urlString withTitle:[urlString lastPathComponent]];
            } else {
                NSLog(@"[Player] openURL - sending to yt-dlp for resolution");
                // Resolve via yt-dlp
                [self updateStatus:[NSString stringWithFormat:@"Resolving URL via yt-dlp..."]];
                [progressIndicator setHidden:NO];
                [progressIndicator startAnimation:self];
                [_ytdlpBackend setFormatSpec:[PreferencesController selectedFormat]];
                [_ytdlpBackend resolveURL:urlString];
            }
        } else {
            NSLog(@"[Player] openURL - non-http URL, routing to radio manager: %@",
                        urlString);
            // Try as radio stream (non-http or bare stream URL)
            [[RadioManager sharedManager] playURL:urlString];
        }
    }
}

- (IBAction)playPause:(id)sender
{
    if (playerMode == PlayerModeRadio) {
        if ([[RadioManager sharedManager] isPlaying]) {
            [[RadioManager sharedManager] stop];
        } else {
            [self radioPlaySelected];
        }
        return;
    }
    [self togglePlayPause];
}

- (IBAction)stop:(id)sender
{
    if (playerMode == PlayerModeRadio) {
        [self radioStop:sender];
        return;
    }
    [self stopPlayback];
}

- (IBAction)previousTrack:(id)sender
{
    if (playerMode == PlayerModeRadio) {
        [self radioPreviousStation];
        return;
    }
    if ([playlist count] == 0) return;

    int newIndex;
    if (shuffleEnabled) {
        // Pick a random track (different from current)
        if ([playlist count] == 1) {
            newIndex = 0;
        } else {
            do {
                newIndex = random() % (int)[playlist count];
            } while (newIndex == currentIndex);
        }
    } else {
        newIndex = currentIndex - 1;
        if (newIndex < 0)
            newIndex = (repeatEnabled) ? (int)[playlist count] - 1 : 0;
    }
    [self playFromPlaylistAtIndex:newIndex];
}

- (IBAction)nextTrack:(id)sender
{
    if (playerMode == PlayerModeRadio) {
        [self radioNextStation];
        return;
    }
    if ([playlist count] == 0) return;

    int newIndex;
    if (shuffleEnabled) {
        // Pick a random track (different from current)
        if ([playlist count] == 1) {
            newIndex = 0;
        } else {
            do {
                newIndex = random() % (int)[playlist count];
            } while (newIndex == currentIndex);
        }
    } else {
        newIndex = currentIndex + 1;
        if (newIndex >= (int)[playlist count])
            newIndex = (repeatEnabled) ? 0 : (int)[playlist count] - 1;
    }
    [self playFromPlaylistAtIndex:newIndex];
}

- (IBAction)seekToTime:(id)sender
{
    if (!avPlayer && !audioPlayer) return;

    double percentage = [timeSlider doubleValue] / 100.0;

    if (avPlayer) {
        AVAsset *asset = [playerItem asset];
        CMTime duration = [asset duration];
        double durSec = CMTimeGetSeconds(duration);
        if (durSec > 0) {
            CMTime seekTime = CMTimeMakeWithSeconds(percentage * durSec, 1);
            [avPlayer seekToTime:seekTime];
        }
    } else if (audioPlayer) {
        // Seek using NSSound's setCurrentTime: on the underlying sound object
        NSSound *sound = [audioPlayer valueForKey:@"sound"];
        if (sound && [sound respondsToSelector:@selector(setCurrentTime:)]) {
            // Get duration to calculate target time from percentage
            NSTimeInterval dur = [sound duration];
            if (dur > 0) {
                NSTimeInterval targetTime = percentage * dur;
                [sound setCurrentTime:targetTime];
            }
        }
    }
}

- (IBAction)toggleRepeat:(id)sender
{
    repeatEnabled = !repeatEnabled;
    [repeatMenuItem setState:repeatEnabled ? NSOnState : NSOffState];
    [[NSUserDefaults standardUserDefaults] setBool:repeatEnabled forKey:@"PlayerRepeatEnabled"];
    [self updateStatus:repeatEnabled ? @"Repeat on" : @"Repeat off"];
}

- (IBAction)toggleShuffle:(id)sender
{
    shuffleEnabled = !shuffleEnabled;
    [shuffleMenuItem setState:shuffleEnabled ? NSOnState : NSOffState];
    [[NSUserDefaults standardUserDefaults] setBool:shuffleEnabled forKey:@"PlayerShuffleEnabled"];
    [self updateStatus:shuffleEnabled ? @"Shuffle on" : @"Shuffle off"];
}

#pragma mark - Playback Control

- (void)loadFile:(NSString *)filePath
{
    if (!filePath || ![filePath length]) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:filePath]) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"File Not Found"];
        [alert setInformativeText:[NSString stringWithFormat:
            @"The file '%@' could not be found.", [filePath lastPathComponent]]];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert runModal];
        [alert release];
        return;
    }

    [self stopPlayback];

    [currentFilePath release];
    currentFilePath = [filePath retain];

    isVideo = [self isVideoFile:filePath];

    // Exit radio mode when loading a local file
    if (playerMode == PlayerModeRadio) {
        [self exitRadioMode];
    }

    [self updateStatus:[NSString stringWithFormat:@"Loading %@...", [filePath lastPathComponent]]];
    [progressIndicator setHidden:NO];
    [progressIndicator startAnimation:self];

    if (isVideo) {
        // Keep AVURLAsset for metadata extraction and cover art
        NSURL *url = [NSURL fileURLWithPath:filePath];
        urlAsset = [[AVURLAsset alloc] initWithURL:url options:nil];

        // Use FFmpeg-based StreamPlayer for local video files.
        // GNUstep's AVFoundation does not support video rendering,
        // but StreamPlayer decodes video frames via FFmpeg and
        // renders them through VideoRenderView.
        [[StreamPlayer sharedPlayer] stop];
        [[StreamPlayer sharedPlayer] close];
        [[StreamPlayer sharedPlayer] setDelegate:self];

        NSError *err = nil;
        if ([[StreamPlayer sharedPlayer] openURL:filePath error:&err]) {
            _usingStreamPlayer = YES;
            if ([[StreamPlayer sharedPlayer] hasVideo]) {
                // Show videoView immediately — a video track was found
                [videoView setHidden:NO];
                [flowView setHidden:YES];
            } else {
                // Audio-only file with a video extension — show flow
                [videoView setHidden:YES];
                [flowView setHidden:NO];
            }
        } else {
            NSLog(@"[Player] StreamPlayer failed for %@: %@ — falling back to AVPlayer audio-only",
                  filePath, [err localizedDescription]);
            [videoView setHidden:YES];
            [flowView setHidden:NO];
            playerItem = [[AVPlayerItem alloc] initWithAsset:urlAsset];
            avPlayer = [[AVPlayer alloc] initWithPlayerItem:playerItem];
            [avPlayer setActionAtItemEnd:AVPlayerActionAtItemEndPause];
            _usingStreamPlayer = NO;
        }
    } else {
        [videoView setHidden:YES];
        [flowView setHidden:NO];

        NSURL *url = [NSURL fileURLWithPath:filePath];

        // Create AVURLAsset for metadata and cover art extraction
        [urlAsset release];
        urlAsset = [[AVURLAsset alloc] initWithURL:url options:nil];

        NSError *error = nil;
        audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];

        if (!audioPlayer) {
            [progressIndicator setHidden:YES];
            [progressIndicator stopAnimation:self];
            if (!_soundAlertShown) {
                _soundAlertShown = YES;
                NSString *errMsg = error ? [error localizedDescription] : @"Unknown error";
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:@"Failed to Load File"];
                [alert setInformativeText:[NSString stringWithFormat:
                    @"Unable to play '%@': %@", [filePath lastPathComponent], errMsg]];
                [alert setAlertStyle:NSWarningAlertStyle];
                [alert runModal];
                [alert release];
            }
            [self updateStatus:@"Failed to load file"];
            return;
        }

        [audioPlayer setVolume:localVolume];
    }

    [self updateMetadata];
    [self addToPlaylist:filePath];

    // Extract and cache cover art for the ItemFlow view
    NSLog( @"[Player] requesting cover art for %@", filePath);
    NSImage *cover = [self extractCoverArtForFile:filePath];
    if (cover) {
        NSLog( @"[Player] cover art obtained, caching for ItemFlow");
        [coverImages setObject:cover forKey:filePath];
    } else {
        NSLog( @"[Player] no cover art available, ItemFlow will show placeholder");
    }

    // Keep the flow view's internal array in sync with the playlist size
    [flowView reloadData];
    [flowView updateTexturesForIndices:[NSIndexSet indexSetWithIndex:currentIndex]];

    [playButton setEnabled:YES];
    [stopButton setEnabled:YES];
    [previousButton setEnabled:([playlist count] > 1)];
    [nextButton setEnabled:([playlist count] > 1)];

    [self updateDurationDisplay];

    [progressIndicator setHidden:YES];
    [progressIndicator stopAnimation:self];
    [self updateStatus:[NSString stringWithFormat:@"Loaded: %@", [filePath lastPathComponent]]];
}

- (void)togglePlayPause
{
    if (playbackState == PlayerPlaybackStatePlaying) {
        [self pause];
    } else if (playbackState == PlayerPlaybackStatePaused) {
        [self play];
    } else if (playbackState == PlayerPlaybackStateStopped && currentFilePath) {
        [self loadFile:currentFilePath];
        [self play];
    }
}

- (BOOL)window:(NSWindow *)window performKeyEquivalent:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] == 0) return NO;
    unichar c = [chars characterAtIndex:0];
    NSUInteger flags = [event modifierFlags];

    BOOL isCmd = (flags & NSCommandKeyMask) != 0;
    BOOL isCtrl = (flags & NSControlKeyMask) != 0;
    BOOL isAlt = (flags & NSAlternateKeyMask) != 0;
    BOOL hasMod = isCmd || isCtrl || isAlt;

    // Don't intercept when a text input is first responder
    NSResponder *first = [window firstResponder];
    if (first && [first isKindOfClass:[NSTextField class]] && [(NSTextField *)first isEditable])
        return NO;

    if (c == ' ' && !hasMod) {
        [self playPause:nil];
        return YES;
    }
    if (c == NSLeftArrowFunctionKey && !hasMod) {
        [self seekRelative:-5.0];
        return YES;
    }
    if (c == NSRightArrowFunctionKey && !hasMod) {
        [self seekRelative:5.0];
        return YES;
    }
    if (c == NSUpArrowFunctionKey && !hasMod) {
        [self adjustVolume:0.05];
        return YES;
    }
    if (c == NSDownArrowFunctionKey && !hasMod) {
        [self adjustVolume:-0.05];
        return YES;
    }
    if ((c == 'm' || c == 'M') && !hasMod) {
        [self toggleMute];
        return YES;
    }
    return NO;
}

- (BOOL)handleMediaKey:(unichar)c
{
    // Don't intercept when a text input is first responder
    NSResponder *first = [[self mainWindow] firstResponder];
    if (first && [first isKindOfClass:[NSTextField class]] && [(NSTextField *)first isEditable])
        return NO;

    switch (c) {
        case ' ': [self togglePlayPause]; return YES;
        case NSLeftArrowFunctionKey: [self seekRelative:-5.0]; return YES;
        case NSRightArrowFunctionKey: [self seekRelative:5.0]; return YES;
        case NSUpArrowFunctionKey: [self adjustVolume:0.05]; return YES;
        case NSDownArrowFunctionKey: [self adjustVolume:-0.05]; return YES;
        case 'm': case 'M': [self toggleMute]; return YES;
        default: return NO;
    }
}

- (void)seekRelative:(NSTimeInterval)delta
{
    if (!avPlayer && !audioPlayer) return;

    if (avPlayer) {
        AVAsset *asset = [playerItem asset];
        CMTime dur = [asset duration];
        double durSec = CMTimeGetSeconds(dur);
        if (durSec <= 0) return;
        CMTime cur = [avPlayer currentTime];
        double curSec = CMTimeGetSeconds(cur);
        double newSec = fmax(0, fmin(durSec, curSec + delta));
        CMTime seekTo = CMTimeMakeWithSeconds(newSec, 1);
        [avPlayer seekToTime:seekTo];
    } else if (audioPlayer) {
        NSSound *sound = [audioPlayer valueForKey:@"sound"];
        if (sound && [sound respondsToSelector:@selector(currentTime)]
                 && [sound respondsToSelector:@selector(setCurrentTime:)]
                 && [sound respondsToSelector:@selector(duration)]) {
            NSTimeInterval cur = [sound currentTime];
            NSTimeInterval dur = [sound duration];
            if (dur <= 0) return;
            NSTimeInterval newTime = fmax(0, fmin(dur, cur + delta));
            [sound setCurrentTime:newTime];
        }
    }
}

- (void)adjustVolume:(float)delta
{
    if (playerMode == PlayerModeRadio) {
        float vol = [volumeSlider floatValue] + delta;
        vol = fmax(0.0f, fmin(1.0f, vol));
        [volumeSlider setFloatValue:vol];
        [self radioVolumeChanged:nil];
    } else {
        float vol = localVolume + delta;
        vol = fmax(0.0f, fmin(1.0f, vol));
        localVolume = vol;
        [volumeSlider setFloatValue:vol];
        if (audioPlayer) {
            [audioPlayer setVolume:vol];
        }
    }
}

- (void)toggleMute
{
    BOOL isMuted = ([muteCheckbox state] == NSOnState);
    [muteCheckbox setState:isMuted ? NSOffState : NSOnState];
    [self radioMuteToggled:nil];
}

- (void)play
{
    if (_usingStreamPlayer) {
        NSLog(@"Player: play via StreamPlayer (FFmpeg) (%@)", currentFilePath);
        [[StreamPlayer sharedPlayer] play];
        playbackState = PlayerPlaybackStatePlaying;
        [playButton setImage:[self iconPause]];
        if (!playbackTimer) {
            playbackTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5
                                                              target:self
                                                            selector:@selector(playbackTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES] retain];
        }
        return;
    }

    if (avPlayer) {
        NSLog(@"Player: play via AVPlayer (%@)", currentFilePath);
        NSLog(@"[Player]   AVPlayerItem status: %ld, error: %@",
              (long)[playerItem status], [[playerItem error] localizedDescription]);
        [avPlayer play];
        playbackState = PlayerPlaybackStatePlaying;
        [playButton setImage:[self iconPause]];
        if (!playbackTimer) {
            playbackTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5
                                                              target:self
                                                            selector:@selector(playbackTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES] retain];
        }
    } else if (audioPlayer) {
        NSLog(@"Player: play via AVAudioPlayer (%@)", currentFilePath);
        BOOL result = [audioPlayer play];
        NSLog(@"Player: AVAudioPlayer play returned %d", result);
        if (result) {
            NSLog(@"Player: AVAudioPlayer isPlaying=%d", [audioPlayer isPlaying]);
            playbackState = PlayerPlaybackStatePlaying;
            [playButton setImage:[self iconPause]];
            if (!playbackTimer) {
                playbackTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5
                                                                  target:self
                                                                selector:@selector(playbackTimerFired:)
                                                                userInfo:nil
                                                                 repeats:YES] retain];
            }
        } else {
            NSLog(@"Player: AVAudioPlayer play returned NO, attempting reload");
            // AVAudioPlayer may fail to resume after pause; reload the file
            if (currentFilePath) {
                [self loadFile:currentFilePath];
                if (audioPlayer) {
                    result = [audioPlayer play];
                    if (result) {
                        playbackState = PlayerPlaybackStatePlaying;
                        [playButton setImage:[self iconPause]];
                    }
                }
            }
            if (!result && !_soundAlertShown) {
                _soundAlertShown = YES;
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:@"Playback Failed"];
                [alert setInformativeText:@"Could not open the audio device. Check that your system sound configuration is working."];
                [alert setAlertStyle:NSWarningAlertStyle];
                [alert runModal];
                [alert release];
            }
        }
    }
}

- (void)pause
{
    if (_usingStreamPlayer) {
        [[StreamPlayer sharedPlayer] pause];
        playbackState = PlayerPlaybackStatePaused;
        [playButton setImage:[self iconPlay]];
        return;
    }

    if (avPlayer) {
        [avPlayer pause];
    } else if (audioPlayer) {
        [audioPlayer pause];
    }
    playbackState = PlayerPlaybackStatePaused;
    [playButton setImage:[self iconPlay]];
}

- (void)stopPlayback
{
    NSLog(@"[Player] stopPlayback called (playbackState=%ld)", (long)playbackState);

    if (avPlayer) {
        [avPlayer pause];
        [avPlayer seekToTime:kCMTimeZero];
        [avPlayer release];
        avPlayer = nil;
    }
    if (playerItem) {
        [playerItem release];
        playerItem = nil;
    }
    if (audioPlayer) {
        [audioPlayer stop];
        [audioPlayer release];
        audioPlayer = nil;
    }
    // Stop FFmpeg stream player (handles both audio and video streaming)
    [[StreamPlayer sharedPlayer] stop];
    [[StreamPlayer sharedPlayer] close];
    _usingStreamPlayer = NO;

    playbackState = PlayerPlaybackStateStopped;
    [playButton setImage:[self iconPlay]];

    if (!isFullscreen) {
        [timeSlider setDoubleValue:0.0];
        [currentTimeLabel setStringValue:@"0:00"];
    }

    if (playbackTimer) {
        [playbackTimer invalidate];
        [playbackTimer release];
        playbackTimer = nil;
    }

    // Hide video display, show flow view
    [videoView setHidden:YES];
    [flowView setHidden:NO];
    [_videoRenderView setFrameData:nil width:0 height:0];
}

- (void)updatePlaybackUI
{
    if (playbackState == PlayerPlaybackStatePlaying) {
        [playButton setImage:[self iconPause]];
    } else {
        [playButton setImage:[self iconPlay]];
    }
}

#pragma mark - Metadata

- (void)updateMetadata
{
    if (!currentFilePath) return;

    NSString *filename = [currentFilePath lastPathComponent];
    NSString *title = filename;
    NSString *artist = @"";
    NSString *album = @"";
    NSString *composer = @"";
    NSString *genre = @"";
    NSString *track = @"";

    if (urlAsset) {
        NSArray *metadata = [urlAsset commonMetadata];
        for (AVMetadataItem *item in metadata) {
            id key = [item key];
            if (![key isKindOfClass:[NSString class]]) continue;

            if ([key isEqual:AVMetadataCommonKeyTitle]) {
                if ([item stringValue]) title = [item stringValue];
            } else if ([key isEqual:AVMetadataCommonKeyArtist]) {
                if ([item stringValue]) artist = [item stringValue];
            } else if ([key isEqual:AVMetadataCommonKeyAlbumName]) {
                if ([item stringValue]) album = [item stringValue];
            } else if ([key isEqual:AVMetadataCommonKeyComposer]) {
                if ([item stringValue]) composer = [item stringValue];
            } else if ([key isEqual:AVMetadataCommonKeyGenre]) {
                if ([item stringValue]) genre = [item stringValue];
            } else if ([key isEqual:AVMetadataCommonKeyTrackNumber]) {
                if ([item stringValue]) track = [item stringValue];
            }
        }
    }

    if ([title isEqualToString:filename]) {
        title = [filename stringByDeletingPathExtension];
    }

    [titleLabel setStringValue:title];
    [artistLabel setStringValue:artist];
    [albumLabel setStringValue:album];

    // Build a compact details line from genre | composer | track
    NSMutableString *details = [NSMutableString string];
    if ([genre length] > 0) {
        [details appendString:genre];
    }
    if ([composer length] > 0) {
        if ([details length] > 0) [details appendString:@"  ·  "];
        [details appendString:composer];
    }
    if ([track length] > 0) {
        if ([details length] > 0) [details appendString:@"  ·  "];
        [details appendFormat:@"Track %@", track];
    }
    [detailsLabel setStringValue:details];

    [mainWindow setTitle:[NSString stringWithFormat:@"Player - %@", title]];
}

#pragma mark - ItemFlowView Data Source

- (NSUInteger)numberOfItemsInItemFlowView:(ItemFlowView *)view
{
    if (playerMode == PlayerModeRadio) {
        return [[[RadioManager sharedManager] stations] count];
    }
    return [playlist count];
}

- (NSImage *)itemFlowView:(ItemFlowView *)view imageAtIndex:(NSUInteger)index
{
    if (playerMode == PlayerModeRadio) {
        NSArray *stations = [[RadioManager sharedManager] stations];
        if (index >= [stations count]) return nil;
        RadioStation *station = [stations objectAtIndex:index];
        return [[RadioManager sharedManager] imageForStation:station];
    }
    if (index >= [playlist count]) return nil;
    NSString *path = [playlist objectAtIndex:index];
    return [coverImages objectForKey:path];
}

#pragma mark - ItemFlowView Delegate

- (void)itemFlowView:(ItemFlowView *)view didSelectItemAtIndex:(NSUInteger)index
{
    if (_suppressFlowSelection) return;
    if (playerMode == PlayerModeRadio) {
        NSArray *stations = [[RadioManager sharedManager] stations];
        if (index >= [stations count]) return;
        [self schedulePlayStation:[stations objectAtIndex:index]];
        return;
    }
    // Suppress re-selection of the already-playing track
    if ((int)index == currentIndex && playbackState != PlayerPlaybackStateStopped) {
        return;
    }
    if (index < [playlist count]) {
        [self playFromPlaylistAtIndex:(int)index];
    }
}

/// Schedule a radio station for playback after the debounce delay.
/// All station selection paths (ItemFlow, menu, prev/next, search) route
/// through here so that rapid selections don't restart the stream each time.
- (void)schedulePlayStation:(RadioStation *)station
{
    if (!station) return;

    RadioManager *rm = [RadioManager sharedManager];

    // Skip if already playing this station
    if ([rm isPlaying] && [[rm currentStationName] isEqualToString:[station name]]) {
        return;
    }

    // Ensure we're in radio mode
    if (playerMode != PlayerModeRadio) {
        [self enterRadioMode];
    }

    // Debounce: update pending station and reset the idle timer.
    // As long as selections keep coming within 500ms, checkDebounce will
    // keep rescheduling itself and never fire the actual playback.
    if (_pendingRadioStation != station) {
        [_pendingRadioStation release];
        _pendingRadioStation = [station retain];
    }
    _lastSelectionTime = [[NSDate date] timeIntervalSince1970];

    if (!_debounceScheduled) {
        _debounceScheduled = YES;
        [self performSelector:@selector(checkDebounce)
                   withObject:nil
                   afterDelay:0.5];
    }
}

- (void)checkDebounce
{
    _debounceScheduled = NO;

    // If a new selection came in while we were waiting, reschedule
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - _lastSelectionTime;
    if (elapsed < 0.499) {  // fudge for floating-point
        _debounceScheduled = YES;
        NSTimeInterval remaining = 0.5 - elapsed;
        if (remaining < 0.01) remaining = 0.01;
        [self performSelector:@selector(checkDebounce)
                   withObject:nil
                   afterDelay:remaining];
        return;
    }

    [self fireDebouncedStation];
}

- (void)fireDebouncedStation
{
    _debounceScheduled = NO;

    if (!_pendingRadioStation) return;
    RadioManager *rm = [RadioManager sharedManager];

    // Skip if already playing this station
    if ([rm isPlaying] && [[rm currentStationName] isEqualToString:[_pendingRadioStation name]]) {
        [_pendingRadioStation release];
        _pendingRadioStation = nil;
        return;
    }

    // Optimistically update button to playing state before stream starts
    [playButton setImage:[self iconPause]];
    [stopButton setEnabled:YES];
    [rm playStation:_pendingRadioStation];

    [_pendingRadioStation release];
    _pendingRadioStation = nil;
}

#pragma mark - Cover Art Extraction

- (NSImage *)extractCoverArtForFile:(NSString *)filePath
{
    if (!filePath) {
        NSLog( @"[Player] extractCoverArtForFile: nil path, returning nil");
        return nil;
    }

    NSLog( @"[Player] extractCoverArtForFile: %@", filePath);

    // Embedded artwork via AVFoundation

    NSURL *url = [NSURL fileURLWithPath:filePath];
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    NSImage *cover = nil;

    NSArray *metadata = [asset commonMetadata];
    NSLog( @"[Player]   AVAsset commonMetadata count: %tu", [metadata count]);

    for (AVMetadataItem *item in metadata) {
        id key = [item key];
        NSString *keyDesc = [key isKindOfClass:[NSString class]] ? (NSString *)key : [key description];
        NSLog( @"[Player]   metadata item key=%@ valueClass=%@",
                    keyDesc, NSStringFromClass([[item value] class]));

        if ([key isKindOfClass:[NSString class]] &&
            [(NSString *)key isEqualToString:AVMetadataCommonKeyArtwork]) {
            id value = [item value];
            if ([value isKindOfClass:[NSData class]]) {
                NSData *data = (NSData *)value;
                NSLog( @"[Player]   artwork NSData length=%tu bytes", [data length]);

                cover = [[NSImage alloc] initWithData:data];
                if (cover) {
                    NSLog( @"[Player]   embedded artwork decoded OK (size=%@)",
                                NSStringFromSize([cover size]));
                    [cover autorelease];
                } else {
                    NSLog( @"[Player]   embedded artwork data did not produce an NSImage");
                }
            } else {
                NSLog( @"[Player]   artwork key found but value is %@, not NSData",
                            NSStringFromClass([value class]));
            }
            break;  // only one artwork item expected
        }
    }

    if (!cover) {
        NSLog( @"[Player]   no artwork found via AVFoundation");
    }

    [asset release];
    return cover;
}

#pragma mark - Batch Cover Loading

- (void)loadCoverArtForAllPlaylistItems
{
    NSInteger count = [playlist count];
    if (count == 0) return;

    NSLog( @"[Player] loadCoverArtForAllPlaylistItems: %ld items", (long)count);

    // Collect paths that still need a cover
    NSMutableArray *pathsToExtract = [NSMutableArray array];
    for (NSInteger i = 0; i < count; i++) {
        NSString *path = [playlist objectAtIndex:i];
        if ([coverImages objectForKey:path] == nil) {
            [pathsToExtract addObject:path];
        }
    }

    // If all covers are already cached, just refresh textures on main
    if ([pathsToExtract count] == 0) {
        [flowView setItemCount:(NSUInteger)count];
        NSMutableIndexSet *indices = [NSMutableIndexSet indexSet];
        for (NSInteger i = 0; i < count; i++) {
            if ([coverImages objectForKey:[playlist objectAtIndex:i]]) {
                [indices addIndex:(NSUInteger)i];
            }
        }
        if ([indices count] > 0) {
            [flowView updateTexturesForIndices:indices];
        }
        return;
    }

    // Retain for MRC — released in the main-thread callback
    [pathsToExtract retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @autoreleasepool {
            // Extract covers on background thread
            NSMutableDictionary *newCovers = [NSMutableDictionary dictionary];
            for (NSString *path in pathsToExtract) {
                NSImage *cover = [self extractCoverArtForFile:path];
                if (cover) {
                    [newCovers setObject:cover forKey:path];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                // Merge extracted covers into the cache
                for (NSString *path in newCovers) {
                    [coverImages setObject:[newCovers objectForKey:path] forKey:path];
                }
                [pathsToExtract release];

                // Update ItemFlow with new covers
                [flowView setItemCount:(NSUInteger)count];
                NSMutableIndexSet *indices = [NSMutableIndexSet indexSet];
                for (NSInteger i = 0; i < count; i++) {
                    if ([coverImages objectForKey:[playlist objectAtIndex:i]]) {
                        [indices addIndex:(NSUInteger)i];
                    }
                }
                if ([indices count] > 0) {
                    [flowView updateTexturesForIndices:indices];
                }
            });
        }
    });
}

- (NSString *)formatTime:(CMTime)time
{
    double totalSeconds = CMTimeGetSeconds(time);
    if (totalSeconds <= 0 || isnan(totalSeconds) || isinf(totalSeconds))
        return @"0:00";
    return [self formatTimeInterval:totalSeconds];
}

- (NSString *)formatTimeInterval:(NSTimeInterval)interval
{
    if (interval < 0 || isnan(interval) || isinf(interval))
        return @"0:00";
    int total = (int)round(interval);
    int hours = total / 3600;
    int mins = (total % 3600) / 60;
    int secs = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%d:%02d:%02d", hours, mins, secs];
    }
    return [NSString stringWithFormat:@"%d:%02d", mins, secs];
}

#pragma mark - Playlist

- (BOOL)addToPlaylist:(NSString *)filePath
{
    if (!filePath) return NO;
    // Standardize path for consistent comparison, but skip URLs
    if ([filePath rangeOfString:@"://"].location == NSNotFound) {
        filePath = [filePath stringByStandardizingPath];
    }
    for (NSString *existing in playlist) {
        if ([existing isEqualToString:filePath]) {
            currentIndex = (int)[playlist indexOfObject:filePath];
            return NO;
        }
    }
    [playlist addObject:filePath];
    currentIndex = (int)[playlist count] - 1;
    return YES;
}

- (void)playFromPlaylistAtIndex:(int)index
{
    if (index < 0 || index >= (int)[playlist count]) return;
    currentIndex = index;
    NSString *fp = [playlist objectAtIndex:index];
    if (fp) {
        [self loadFile:fp];
        [self play];
        // Animate the flow view to show the currently playing track
        [flowView setSelectedIndex:index];
    }
}

#pragma mark - Timer

- (void)playbackTimerFired:(NSTimer *)timer
{
    if (playbackState == PlayerPlaybackStateStopped) return;

    if (_usingStreamPlayer) {
        NSTimeInterval curSec = [[StreamPlayer sharedPlayer] currentTime];
        NSTimeInterval durSec = [[StreamPlayer sharedPlayer] duration];
        if (durSec > 0 && curSec >= 0) {
            double pct = (curSec / durSec) * 100.0;
            if (!isFullscreen) {
                [timeSlider setDoubleValue:pct];
            }
            [currentTimeLabel setStringValue:[self formatTimeInterval:curSec]];
            [totalTimeLabel setStringValue:[self formatTimeInterval:durSec]];
        }
        // End-of-track is handled by streamPlayerDidStop: delegate
        return;
    }

    if (avPlayer) {
        CMTime current = [avPlayer currentTime];
        CMTime duration = [[playerItem asset] duration];
        double durSec = CMTimeGetSeconds(duration);
        double curSec = CMTimeGetSeconds(current);

        if (durSec > 0 && curSec >= 0) {
            double pct = (curSec / durSec) * 100.0;
            if (!isFullscreen) {
                [timeSlider setDoubleValue:pct];
            }
            [currentTimeLabel setStringValue:[self formatTimeInterval:curSec]];
            [totalTimeLabel setStringValue:[self formatTimeInterval:durSec]];
        }

        if (durSec > 0 && curSec >= durSec) {
            [self stopPlayback];
        }
    } else if (audioPlayer) {
        // AVAudioPlayer wraps NSSound internally; read position from it.
        NSSound *sound = [audioPlayer valueForKey:@"sound"];
        if (sound) {
            NSTimeInterval curSec = [sound currentTime];
            NSTimeInterval durSec = [sound duration];
            if (durSec > 0 && curSec >= 0) {
                double pct = (curSec / durSec) * 100.0;
                if (!isFullscreen) {
                    [timeSlider setDoubleValue:pct];
                }
                [currentTimeLabel setStringValue:[self formatTimeInterval:curSec]];
                [totalTimeLabel setStringValue:[self formatTimeInterval:durSec]];
            }
        }

        if (![audioPlayer isPlaying] && playbackState == PlayerPlaybackStatePlaying) {
            [self stopPlayback];
            if ([playlist count] > 1) {
                if (repeatEnabled || shuffleEnabled) {
                    [self nextTrack:self];
                } else {
                    int nextIdx = currentIndex + 1;
                    if (nextIdx < (int)[playlist count]) {
                        [self playFromPlaylistAtIndex:nextIdx];
                    }
                }
            } else if (repeatEnabled && [playlist count] == 1) {
                [self playFromPlaylistAtIndex:0];
            }
        }
    }
}

- (void)updateDurationDisplay
{
    if (_usingStreamPlayer) {
        NSTimeInterval dur = [[StreamPlayer sharedPlayer] duration];
        if (dur > 0) {
            [totalTimeLabel setStringValue:[self formatTimeInterval:dur]];
        } else {
            [totalTimeLabel setStringValue:@"--:--"];
        }
    } else if (urlAsset) {
        CMTime duration = [urlAsset duration];
        if (CMTimeGetSeconds(duration) > 0) {
            [totalTimeLabel setStringValue:[self formatTime:duration]];
        }
    } else if (audioPlayer) {
        NSSound *sound = [audioPlayer valueForKey:@"sound"];
        NSTimeInterval dur = [sound respondsToSelector:@selector(duration)] ? [sound duration] : 0;
        if (dur > 0) {
            [totalTimeLabel setStringValue:[self formatTimeInterval:dur]];
        } else {
            [totalTimeLabel setStringValue:@"--:--"];
        }
    } else if (currentFilePath) {
        [totalTimeLabel setStringValue:@"--:--"];
    }
}

#pragma mark - Utility

- (void)updateStatus:(NSString *)status
{
    NSLog( @"Player: %@", status);
}

- (void)showOpenPanel
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:YES];
    [panel setAllowsMultipleSelection:YES];
    [panel setAllowedFileTypes:@[
        @"mp3", @"wav", @"aiff", @"aif", @"m4a", @"flac", @"ogg",
        @"mp4", @"m4v", @"mov", @"avi", @"mkv", @"webm"
    ]];

    if ([panel runModal] == NSFileHandlingPanelOKButton) {
        NSArray *urls = [panel URLs];
        if ([urls count] == 0) return;

        // Clear existing playlist and stop playback — Open replaces, not appends
        [self stopPlayback];
        [playlist removeAllObjects];
        [flowView reloadData];
        currentIndex = 0;

        // Collect all paths (files and directories)
        NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[urls count]];
        for (NSURL *url in urls) {
            [paths addObject:[url path]];
        }

        // Reuse the drag-and-drop handler which recursively scans folders
        // and filters for supported media files
        if ([paths count] == 1) {
            BOOL isDir = NO;
            [[NSFileManager defaultManager] fileExistsAtPath:[paths firstObject] isDirectory:&isDir];
            if (!isDir) {
                // Single file — original fast path
                [self loadFile:[paths firstObject]];
                [self play];
                return;
            }
        }
        [self handleDroppedFiles:paths];
    }
}

- (BOOL)isVideoFile:(NSString *)path
{
    NSString *ext = [[path pathExtension] lowercaseString];
    return [@[@"mp4", @"m4v", @"mov", @"avi", @"mkv", @"webm", @"flv", @"wmv"]
        containsObject:ext];
}

- (BOOL)isAudioFile:(NSString *)path
{
    NSString *ext = [[path pathExtension] lowercaseString];
    return [@[@"mp3", @"wav", @"aiff", @"aif", @"m4a", @"flac", @"ogg", @"wma"]
        containsObject:ext];
}

#pragma mark - Drag & Drop (Playlist Management)

- (void)handleDroppedFiles:(NSArray *)filePaths
{
    if (!filePaths || [filePaths count] == 0) return;

    NSMutableArray *validFiles = [NSMutableArray array];

    for (NSString *path in filePaths) {
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) {
            if (isDir) {
                // Recursively scan the folder for supported media files
                NSArray *folderFiles = [self scanFolderForMediaFiles:path];
                [validFiles addObjectsFromArray:folderFiles];
            } else if ([self isAudioFile:path] || [self isVideoFile:path]) {
                [validFiles addObject:path];
            }
        }
    }

    if ([validFiles count] == 0) return;

    // Sort for consistent ordering
    [validFiles sortUsingSelector:@selector(compare:)];

    // Remember whether we were playing before adding
    BOOL wasPlaying = (playbackState != PlayerPlaybackStateStopped);

    // Add all valid files to the playlist (addToPlaylist: handles dedup)
    NSUInteger addedCount = 0;
    for (NSString *file in validFiles) {
        if ([self addToPlaylist:file]) addedCount++;
    }

    // Load cover art for every playlist item immediately
    [self loadCoverArtForAllPlaylistItems];

    // If nothing was playing, start with the first (sorted) file
    if (!wasPlaying && [playlist count] > 0) {
        [self playFromPlaylistAtIndex:0];
    }

    [self updateStatus:[NSString stringWithFormat:@"Added %lu file(s) to playlist",
        (unsigned long)addedCount]];
}

- (NSArray *)scanFolderForMediaFiles:(NSString *)folderPath
{
    NSMutableArray *result = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:folderPath];

    for (NSString *subpath in enumerator) {
        NSString *fullPath = [folderPath stringByAppendingPathComponent:subpath];
        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];
        if (!isDir && ([self isAudioFile:fullPath] || [self isVideoFile:fullPath])) {
            [result addObject:fullPath];
        }
    }

    return result;
}

- (void)restoreWindowTitle
{
    if (currentFilePath) {
        NSString *title = [currentFilePath lastPathComponent];
        // Check if we have a nicer title from metadata
        NSString *metaTitle = [titleLabel stringValue];
        if (metaTitle && [metaTitle length] > 0 &&
            ![metaTitle isEqualToString:@"No file loaded"]) {
            title = metaTitle;
        } else {
            title = [title stringByDeletingPathExtension];
        }
        [mainWindow setTitle:[NSString stringWithFormat:@"Player - %@", title]];
    } else {
        [mainWindow setTitle:@"Player"];
    }
}

#pragma mark - Command Line

- (void)handleCommandLineArguments
{
    [mainWindow orderOut:nil];

    NSArray *args = [[NSProcessInfo processInfo] arguments];
    BOOL showHelp = NO;
    NSMutableArray *filesToOpen = [NSMutableArray array];

    for (int i = 1; i < (int)[args count]; i++) {
        NSString *arg = [args objectAtIndex:i];
        if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) {
            showHelp = YES;
            break;
        } else if (![arg hasPrefix:@"-"]) {
            [filesToOpen addObject:arg];
        }
    }

    if (showHelp) {
        [self printUsageAndExit];
        return;
    }

    // UI was already created in applicationDidFinishLaunching
    if ([filesToOpen count] > 0) {
        [mainWindow makeKeyAndOrderFront:self];

        // Add all files to playlist
        for (NSString *filePath in filesToOpen) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:filePath]) {
                [self addToPlaylist:filePath];
            }
        }

        // Load cover art for every playlist item immediately
        [self loadCoverArtForAllPlaylistItems];

        // Start playing the first file
        if ([playlist count] > 0) {
            [self playFromPlaylistAtIndex:0];
        }
    } else {
        [mainWindow makeKeyAndOrderFront:self];
    }
}

- (void)printUsageAndExit
{
    printf("Player - GNUstep Media Player\n\n");
    printf("Usage: Player [options] [media-file]\n\n");
    printf("Options:\n");
    printf("  -h, --help    Show this help message\n\n");
    printf("If a media file is specified, it will be loaded and played.\n");
    printf("Supported formats: mp3, wav, aiff, m4a, flac, ogg,\n");
    printf("                   mp4, m4v, mov, avi, mkv, webm\n");
    exit(0);
}

- (void)exitApp
{
    [NSApp terminate:self];
}

#pragma mark - Radio Mode: Layout

- (void)layoutRadioMode
{
    NSView *content = [mainWindow contentView];
    NSRect bounds = [content bounds];
    CGFloat W = bounds.size.width;
    CGFloat H = bounds.size.height;
    CGFloat margin = METRICS_CONTENT_SIDE_MARGIN;

    // ---- Search field at top ---- //
    CGFloat searchY = H - METRICS_CONTENT_TOP_MARGIN - 22;
    [searchField setFrame:NSMakeRect(margin, searchY, W - 2 * margin, 22)];
    [searchField setHidden:NO];
    [searchField setAutoresizingMask:NSViewWidthSizable];

    // ---- ItemFlowView (station browser) fills middle ---- //
    CGFloat flowTop = searchY - METRICS_SPACE_8;
    CGFloat flowBottom = METRICS_CONTENT_BOTTOM_MARGIN + 160;  // leave room for controls
    CGFloat flowH = flowTop - flowBottom;
    if (flowH < 100) flowH = 100;

    [flowView setFrame:NSMakeRect(0, flowBottom, W, flowH)];
    [flowView setHidden:NO];
    [videoView setHidden:YES];

    // Center spinner on flow view
    NSSize spinSize = [progressIndicator frame].size;
    [progressIndicator setFrameOrigin:NSMakePoint(
        NSMidX(bounds) - spinSize.width / 2.0,
        flowBottom + flowH / 2.0 - spinSize.height / 2.0)];
    [progressIndicator setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin |
                                           NSViewMinYMargin | NSViewMaxYMargin];

    // Hide local-mode metadata labels
    [titleLabel setHidden:YES];
    [artistLabel setHidden:YES];
    [albumLabel setHidden:YES];
    [detailsLabel setHidden:YES];

    // Hide time slider and labels
    [currentTimeLabel setHidden:YES];
    [timeSlider setHidden:YES];
    [totalTimeLabel setHidden:YES];

    // ---- Status label (shows station name / state) ---- //
    CGFloat statusY = flowBottom - METRICS_SPACE_8 - 16;
    [statusLabel setFrame:NSMakeRect(margin, statusY, W - 2 * margin, 16)];
    [statusLabel setHidden:NO];
    [statusLabel setAutoresizingMask:NSViewWidthSizable];

    // ---- Radio text (ICY StreamTitle + icy-url) below status ---- //
    CGFloat radioTextY = statusY - 4.0 - 32;
    [radioTextLabel setFrame:NSMakeRect(margin, radioTextY, W - 2 * margin, 32)];
    [radioTextLabel setHidden:NO];
    [radioTextLabel setAutoresizingMask:NSViewWidthSizable];

    // ---- Volume controls ---- //
    CGFloat volY = radioTextY - METRICS_SPACE_12 - 22;
    CGFloat volLabelW = 55.0;
    CGFloat sliderMaxW = 180.0;
    CGFloat muteW = 60.0;
    CGFloat volSliderW = W - margin - (margin + volLabelW + METRICS_SPACE_8 + muteW + METRICS_SPACE_8);
    if (volSliderW > sliderMaxW) volSliderW = sliderMaxW;

    [volumeLabel setFrame:NSMakeRect(margin, volY, volLabelW, 22)];
    [volumeLabel setHidden:NO];

    [volumeSlider setFrame:NSMakeRect(margin + volLabelW + METRICS_SPACE_8, volY, volSliderW, 22)];
    [volumeSlider setHidden:NO];
    [volumeSlider setAutoresizingMask:NSViewWidthSizable];

    [muteCheckbox setFrame:NSMakeRect(margin + volLabelW + METRICS_SPACE_8 + volSliderW + METRICS_SPACE_8,
                                       volY + 2, muteW, 18)];
    [muteCheckbox setHidden:NO];

    // ---- Playback controls row ---- //
    CGFloat ctrlY = volY - METRICS_SPACE_12 - 22;
    CGFloat btnW = 36.0;
    CGFloat btnH = 22.0;
    CGFloat gap = 6.0;
    CGFloat fourBtnW = 4 * btnW + 3 * gap;
    CGFloat ctrlStartX = floorf((W - fourBtnW) / 2.0);

    [previousButton setFrame:NSMakeRect(ctrlStartX, ctrlY, btnW, btnH)];
    [playButton setFrame:NSMakeRect(ctrlStartX + btnW + gap, ctrlY, btnW, btnH)];
    [stopButton setFrame:NSMakeRect(ctrlStartX + 2 * (btnW + gap), ctrlY, btnW, btnH)];
    [nextButton setFrame:NSMakeRect(ctrlStartX + 3 * (btnW + gap), ctrlY, btnW, btnH)];

    [previousButton setHidden:NO];
    [playButton setHidden:NO];
    [stopButton setHidden:NO];
    [nextButton setHidden:NO];

    // Hide Open and Fullscreen buttons
    [openButton setHidden:YES];
    [fullscreenButton setHidden:YES];

    // Hide overlay if present
    if (overlayBar && ![overlayBar isHidden]) {
        [overlayBar setHidden:YES];
    }

    // Enable prev/next for station cycling
    NSArray *stations = [[RadioManager sharedManager] stations];
    [previousButton setEnabled:([stations count] > 1)];
    [nextButton setEnabled:([stations count] > 1)];
}

#pragma mark - Radio Mode: Mode Switching

- (IBAction)toggleRadioMode:(id)sender
{
    NSLog(@"[Player] toggleRadioMode: called (sender=%@, playerMode=%ld)", sender, (long)playerMode);
    if (playerMode == PlayerModeRadio) {
        [self exitRadioMode];
    } else {
        [self enterRadioMode];
    }
}

- (void)enterRadioMode
{
    if (playerMode == PlayerModeRadio) return;
    playerMode = PlayerModeRadio;
    NSLog(@"[Player] enterRadioMode");

    // Save current volume slider position for local mode
    localVolume = [volumeSlider floatValue];

    // Immediate visible feedback
    [mainWindow setTitle:@"Player - Internet Radio"];

    // Set up delegate on RadioManager if not done yet
    if (!radioInitialized) {
        [[RadioManager sharedManager] setDelegate:self];
        radioInitialized = YES;
    }

    // Stop any local playback
    [self stopPlayback];

    // Stop radio if playing
    if ([[RadioManager sharedManager] isPlaying]) {
        [[RadioManager sharedManager] stop];
    }

    // Sync slider and RadioManager to persisted radio-mode volume
    [[RadioManager sharedManager] setVolume:radioVolume];
    [volumeSlider setDoubleValue:radioVolume];

    // Persist radio mode and update menu title
    [[NSUserDefaults standardUserDefaults] setInteger:playerMode forKey:@"PlayerMode"];
    [radioModeMenuItem setTitle:@"Exit Radio Mode"];

    // Reload flow view for radio station data
    [flowView reloadData];

    // Load stations
    [statusLabel setStringValue:@"Loading stations..."];
    [[RadioManager sharedManager] loadLocalStations];

    // Update button states
    [playButton setEnabled:YES];
    [stopButton setEnabled:YES];
    [previousButton setEnabled:NO];
    [nextButton setEnabled:NO];
    [playButton setImage:[self iconPlay]];

    [self layoutSubviews];
    [self updateStatus:@"Internet Radio mode"];
}

- (void)exitRadioMode
{
    if (playerMode != PlayerModeRadio) return;
    playerMode = PlayerModeLocal;

    // Save current radio volume before switching away
    radioVolume = [volumeSlider floatValue];
    [[NSUserDefaults standardUserDefaults] setFloat:radioVolume
                                             forKey:@"PlayerRadioVolume"];

    // Stop radio
    if ([[RadioManager sharedManager] isPlaying]) {
        [[RadioManager sharedManager] stop];
    }

    // Restore local-mode volume slider
    [volumeSlider setDoubleValue:localVolume];

    // Persist local mode and update menu title
    [[NSUserDefaults standardUserDefaults] setInteger:playerMode forKey:@"PlayerMode"];
    [radioModeMenuItem setTitle:@"Browse Radio Stations"];

    // Hide radio-only UI elements (volume controls are now managed by layoutNormalMode)
    [searchField setHidden:YES];
    [statusLabel setHidden:YES];

    // Reload flow view back to playlist data
    [flowView reloadData];

    [self layoutSubviews];
    [self updateStatus:@"Local mode"];
}

#pragma mark - Radio Mode: Actions

- (void)radioPlaySelected
{
    NSArray *stations = [[RadioManager sharedManager] stations];
    if ([stations count] == 0) {
        [statusLabel setStringValue:@"No stations loaded. Search for stations first."];
        return;
    }

    NSUInteger selIndex = [flowView selectedIndex];
    if (selIndex >= [stations count]) {
        selIndex = 0;
    }

    RadioStation *station = [stations objectAtIndex:selIndex];
    [self schedulePlayStation:station];
}

- (void)radioPreviousStation
{
    NSArray *stations = [[RadioManager sharedManager] stations];
    if ([stations count] < 2) return;

    NSUInteger selIndex = [flowView selectedIndex];
    if (selIndex == NSNotFound || selIndex >= [stations count]) {
        selIndex = 0;
    }
    selIndex = (selIndex == 0) ? [stations count] - 1 : selIndex - 1;
    [flowView setSelectedIndex:selIndex];
    RadioStation *station = [stations objectAtIndex:selIndex];
    [self schedulePlayStation:station];
}

- (void)radioNextStation
{
    NSArray *stations = [[RadioManager sharedManager] stations];
    if ([stations count] < 2) return;

    NSUInteger selIndex = [flowView selectedIndex];
    if (selIndex == NSNotFound || selIndex >= [stations count]) {
        selIndex = 0;
    }
    selIndex = (selIndex + 1) % [stations count];
    [flowView setSelectedIndex:selIndex];
    RadioStation *station = [stations objectAtIndex:selIndex];
    [self schedulePlayStation:station];
}

- (void)radioSearchAction:(id)sender
{
    NSString *query = [sender stringValue];
    if ([query length] == 0) {
        [[RadioManager sharedManager] loadLocalStations];
    } else {
        [[RadioManager sharedManager] searchStations:query];
    }
}

- (void)openRadioStream:(id)sender
{
    NSString *urlString = [self _inputDialogWithTitle:@"Open Radio Stream"
                                              message:@"Enter a stream URL or station name."
                                          placeholder:@"http://stream.example.com:8000/stream"];

    if ([urlString length] > 0) {
        // Check if the URL looks like a web video platform URL instead of a radio stream
        NSString *lower = [urlString lowercaseString];
        BOOL isWebVideo = NO;
        NSArray *webPlatforms = @[@"youtube.com", @"youtu.be", @"vimeo.com",
                                   @"soundcloud.com", @"twitch.tv", @"dailymotion.com"];
        for (NSString *domain in webPlatforms) {
            if ([lower rangeOfString:domain].location != NSNotFound) {
                isWebVideo = YES;
                break;
            }
        }

        if (isWebVideo && _ytdlpAvailable) {
            NSLog(@"[Player] openRadioStream - detected web video URL, routing to yt-dlp");
            // Update status
            [self updateStatus:@"Resolving URL via yt-dlp..."];
            [progressIndicator setHidden:NO];
            [progressIndicator startAnimation:self];
            [_ytdlpBackend setFormatSpec:[PreferencesController selectedFormat]];
            [_ytdlpBackend resolveURL:urlString];
            return;
        }

        RadioStation *matchedStation = nil;
        for (RadioStation *s in [[RadioManager sharedManager] stations]) {
            if ([[s name] isEqualToString:urlString]) {
                matchedStation = s;
                break;
            }
        }
        if (matchedStation) {
            [self schedulePlayStation:matchedStation];
        } else {
            [[RadioManager sharedManager] playURL:urlString];
        }
    }
}

- (void)radioStop:(id)sender
{
    [[RadioManager sharedManager] stop];
}

- (void)radioVolumeChanged:(id)sender
{
    float vol = [volumeSlider floatValue];
    if (playerMode == PlayerModeRadio) {
        radioVolume = vol;
        [[NSUserDefaults standardUserDefaults] setFloat:radioVolume
                                                 forKey:@"PlayerRadioVolume"];
        [[RadioManager sharedManager] setVolume:vol];
    } else {
        // Local mode — persist and apply
        localVolume = vol;
        [[NSUserDefaults standardUserDefaults] setFloat:localVolume
                                                 forKey:@"PlayerLocalVolume"];
        if (_usingStreamPlayer) {
            // Local video files play through StreamPlayer
            [[StreamPlayer sharedPlayer] setVolume:vol];
        }
        if (audioPlayer) {
            [audioPlayer setVolume:vol];
            // Also try through NSSound directly if available
            NSSound *sound = [audioPlayer valueForKey:@"sound"];
            if (sound) {
                [sound setVolume:vol];
            }
        }
    }
}

- (void)radioMuteToggled:(id)sender
{
    BOOL isMuted = ([muteCheckbox state] == NSOnState);
    if (playerMode == PlayerModeRadio) {
        [[RadioManager sharedManager] setMuted:isMuted];
    } else {
        // Local mode: mute by setting volume to 0, unmute by restoring slider value
        float targetVol = isMuted ? 0.0f : [volumeSlider floatValue];
        if (_usingStreamPlayer) {
            [[StreamPlayer sharedPlayer] setMuted:isMuted];
        }
        if (audioPlayer) {
            [audioPlayer setVolume:targetVol];
            NSSound *sound = [audioPlayer valueForKey:@"sound"];
            if (sound) [sound setVolume:targetVol];
        }
    }
}

- (void)updateRadioUI
{
    BOOL playing = [[RadioManager sharedManager] isPlaying];
    if (playing) {
        [playButton setImage:[self iconPause]];
    } else {
        [playButton setImage:[self iconPlay]];
    }
}

#pragma mark - Input Dialog Helper

/**
 * Build a proper NSPanel modal dialog with a text field.
 *
 * Unlike NSAlert hacks (which fail in GNUstep because [alert window]
 * may not be available before runModal), this creates a dedicated
 * panel that works reliably on macOS and GNUstep.
 */
- (NSString *)_inputDialogWithTitle:(NSString *)title
                            message:(NSString *)message
                        placeholder:(NSString *)placeholder
{
    CGFloat pw = 460.0;
    CGFloat ph = 155.0;

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, pw, ph)
                                                styleMask:NSTitledWindowMask |
                                                          NSClosableWindowMask
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    [panel setTitle:title ?: @"Input"];
    [panel setFloatingPanel:YES];
    [panel center];

    NSView *cv = [panel contentView];
    CGFloat contentWidth = pw - 2 * METRICS_CONTENT_SIDE_MARGIN;

    // Message label
    CGFloat labelY = ph - METRICS_CONTENT_TOP_MARGIN - 34;
    NSTextField *msgLabel = [[[NSTextField alloc]
        initWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, labelY, contentWidth, 34)] autorelease];
    [msgLabel setStringValue:message ?: @""];
    [msgLabel setBezeled:NO];
    [msgLabel setDrawsBackground:NO];
    [msgLabel setEditable:NO];
    [msgLabel setSelectable:NO];
    [msgLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [[msgLabel cell] setLineBreakMode:NSLineBreakByWordWrapping];
    [cv addSubview:msgLabel];

    // Text input field
    CGFloat inputY = labelY - METRICS_SPACE_16 - METRICS_TEXT_INPUT_FIELD_HEIGHT;
    NSTextField *input = [[NSTextField alloc]
        initWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, inputY, contentWidth,
                                 METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    [input setPlaceholderString:placeholder ?: @""];
    [input setEditable:YES];
    [input setSelectable:YES];
    [cv addSubview:input];

    // Buttons — default (OK) in lower-right corner, Cancel to its left per HIG
    CGFloat buttonY = METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat buttonW = METRICS_BUTTON_MIN_WIDTH;
    CGFloat buttonH = METRICS_BUTTON_HEIGHT;

    // OK button (rightmost — lower-right corner)
    CGFloat okX = pw - METRICS_CONTENT_SIDE_MARGIN - buttonW;
    NSButton *okButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(okX, buttonY, buttonW, buttonH)] autorelease];
    [okButton setTitle:@"OK"];
    [okButton setBezelStyle:NSRoundedBezelStyle];
    [okButton setKeyEquivalent:@"\r"];
    [okButton setTag:NSOKButton];
    [okButton setTarget:self];
    [okButton setAction:@selector(_dismissInputDialog:)];
    [cv addSubview:okButton];

    // Cancel button (to the left of OK)
    CGFloat cancelX = okX - METRICS_SPACE_12 - buttonW;
    NSButton *cancelButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(cancelX, buttonY, buttonW, buttonH)] autorelease];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setBezelStyle:NSRoundedBezelStyle];
    [cancelButton setKeyEquivalent:@"\e"];
    [cancelButton setTag:NSCancelButton];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(_dismissInputDialog:)];
    [cv addSubview:cancelButton];

    [panel setInitialFirstResponder:input];
    _modalInputResult = nil;
    _modalInputPanel = panel;
    _modalInputField = input;

    [NSApp runModalForWindow:panel];

    NSString *result = [_modalInputResult autorelease];
    _modalInputResult = nil;
    _modalInputPanel = nil;
    _modalInputField = nil;

    [panel orderOut:self];
    [panel release];
    [input release];

    return result;
}

- (void)_dismissInputDialog:(id)sender
{
    NSString *value = nil;
    if ([sender tag] == NSOKButton && _modalInputField) {
        value = [[_modalInputField stringValue]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([value length] == 0) value = nil;
    }
    [_modalInputResult release];
    _modalInputResult = [value retain];
    _modalInputField = nil;
    [NSApp stopModal];
}

#pragma mark - Open URL / yt-dlp

- (IBAction)openPreferences:(id)sender
{
    if (!_preferencesController) {
        _preferencesController = [[PreferencesController alloc] init];
    }
    [_preferencesController showPreferencesWindow:mainWindow];
}

- (void)playStreamURL:(NSString *)url withTitle:(NSString *)title
{
    NSLog( @"[Player] playStreamURL: %@", url);
    NSLog( @"[Player]   title: %@", title);

    // Switch to local mode (exit radio if active)
    if (playerMode == PlayerModeRadio) {
        [self exitRadioMode];
    }

    [self stopPlayback];

    // Set the title display
    if ([title length] > 0) {
        NSString *displayTitle = [title stringByDeletingPathExtension];
        [titleLabel setStringValue:displayTitle];
        [artistLabel setStringValue:@""];
        [albumLabel setStringValue:@""];
        [detailsLabel setStringValue:@"Streaming URL"];
        [mainWindow setTitle:[NSString stringWithFormat:@"Player - %@", displayTitle]];
        [_pendingStreamTitle release];
        _pendingStreamTitle = [title retain];
    } else {
        [titleLabel setStringValue:@"Streaming..."];
        [artistLabel setStringValue:@""];
        [albumLabel setStringValue:@""];
        [detailsLabel setStringValue:@"Streaming URL"];
        [mainWindow setTitle:@"Player - Streaming"];
    }

    // Load the stream URL in the current audio player
    NSURL *streamURL = [NSURL URLWithString:url];
    if (!streamURL) {
        [self updateStatus:@"Invalid stream URL"];
        return;
    }

    // Show flowView (or cleared videoView) before StreamPlayer.play fires
    // the delegate callback. stopPlayback already set this, but be explicit
    // so the initial state is correct before the delegate runs.
    [_videoRenderView setFrameData:nil width:0 height:0];
    [videoView setHidden:YES];
    [flowView setHidden:NO];

    // For stream URLs (non-file scheme), use StreamPlayer (FFmpeg + libao)
    // which handles Opus, AAC, MP3, and other streaming codecs properly.
    if (![[streamURL scheme] isEqualToString:@"file"]) {
        NSLog(@"[Player] stream URL detected, using StreamPlayer (FFmpeg)");
        @try {
            [[StreamPlayer sharedPlayer] stop];
            [[StreamPlayer sharedPlayer] close];
            [[StreamPlayer sharedPlayer] setDelegate:self];
            NSError *error = nil;
            if ([[StreamPlayer sharedPlayer] openURL:url error:&error]) {
                [[StreamPlayer sharedPlayer] play];
            } else {
                [self updateStatus:[NSString stringWithFormat:@"Stream failed: %@",
                                   [error localizedDescription]]];
                return;
            }
        } @catch (NSException *exception) {
            NSLog(@"[Player] Exception in StreamPlayer: %@", [exception reason]);
            [self updateStatus:[NSString stringWithFormat:@"Stream failed: %@",
                               [exception reason]]];
            return;
        }
    } else {
        @try {
            // Try loading via AVAudioPlayer (works for direct media URLs)
            NSError *error = nil;
            audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:streamURL error:&error];

            if (!audioPlayer && error) {
                // Fallback: use AVPlayer for streaming (HLS, etc.)
                NSLog( @"[Player] AVAudioPlayer failed, trying AVPlayer: %@",
                           [error localizedDescription]);
                [self _setupAVPlayerWithURL:streamURL];
            } else if (audioPlayer) {
                [audioPlayer setVolume:localVolume];
            }
        } @catch (NSException *exception) {
            NSLog( @"[Player] Exception loading stream: %@", [exception reason]);
            [self updateStatus:[NSString stringWithFormat:@"Failed to load stream: %@",
                               [exception reason]]];
            return;
        }
    }

    // Add to playlist as a special entry
    NSString *playlistEntry = url;
    if ([_pendingStreamTitle length] > 0) {
        playlistEntry = [NSString stringWithFormat:@"%@|%@", url, _pendingStreamTitle];
    }
    [self addToPlaylist:playlistEntry];

    [playButton setEnabled:YES];
    [stopButton setEnabled:YES];

    [self play];
    [self updateStatus:@"Streaming..."];
}

/**
 * Set up AVPlayer for streaming a URL.
 * Releases any existing AVPlayer/AVPlayerItem/AVURLAsset first.
 */
- (void)_setupAVPlayerWithURL:(NSURL *)streamURL
{
    if (avPlayer) {
        [avPlayer release];
        avPlayer = nil;
    }
    if (playerItem) {
        [playerItem release];
        playerItem = nil;
    }
    if (urlAsset) {
        [urlAsset release];
        urlAsset = nil;
    }

    urlAsset = [[AVURLAsset alloc] initWithURL:streamURL options:nil];
    playerItem = [[AVPlayerItem alloc] initWithAsset:urlAsset];
    avPlayer = [[AVPlayer alloc] initWithPlayerItem:playerItem];
    [avPlayer setActionAtItemEnd:AVPlayerActionAtItemEndPause];

    // Log player/item status
    NSLog(@"[Player] AVPlayerItem status: %ld", (long)[playerItem status]);
    NSLog(@"[Player] AVPlayer status: %ld", (long)[avPlayer status]);
    if ([playerItem error]) {
        NSLog(@"[Player] AVPlayerItem error: %@", [[playerItem error] localizedDescription]);
    }
}

- (void)checkYTDLPAvailability
{
    NSLog(@"[Player] checkYTDLPAvailability - trying default path: %@",
                [_ytdlpBackend ytdlpPath]);
    _ytdlpAvailable = [_ytdlpBackend checkAvailability];
    if (!_ytdlpAvailable) {
        // Also check the user-configured path
        NSString *configuredPath = [PreferencesController ytdlpPath];
        NSLog(@"[Player] checkYTDLPAvailability - default not found, trying configured: %@",
                    configuredPath);
        if (![configuredPath isEqualToString:@"yt-dlp"]) {
            [_ytdlpBackend setYtdlpPath:configuredPath];
            _ytdlpAvailable = [_ytdlpBackend checkAvailability];
        }
    }
    NSLog(@"[Player] checkYTDLPAvailability - result: %@",
                _ytdlpAvailable ? @"available" : @"not available");
}

#pragma mark - YTDLPBackendDelegate

- (void)ytdlpBackend:(YTDLPBackend *)backend didResolveURL:(NSString *)streamURL
              title:(NSString *)title thumbnail:(NSString *)thumbnailURL
            duration:(NSTimeInterval)duration
{
    NSLog( @"[Player] ytdlpBackend:didResolveURL:");
    NSLog( @"[Player]   streamURL: %@", streamURL);
    NSLog( @"[Player]   title: %@", title);
    NSLog( @"[Player]   thumbnail: %@", thumbnailURL);
    NSLog( @"[Player]   duration: %.1fs", duration);

    [progressIndicator setHidden:YES];
    [progressIndicator stopAnimation:self];

    if ([streamURL length] > 0) {
        NSString *displayTitle = title;
        if ([displayTitle length] == 0) {
            displayTitle = @"Streaming URL";
        }
        [self playStreamURL:streamURL withTitle:displayTitle];
    }
}

- (void)ytdlpBackend:(YTDLPBackend *)backend didFailWithError:(NSString *)error
{
    NSLog( @"[Player] ytdlpBackend:didFailWithError: %@", error);

    [progressIndicator setHidden:YES];
    [progressIndicator stopAnimation:self];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Failed to Resolve URL"];
    [alert setInformativeText:[NSString stringWithFormat:
        @"yt-dlp was unable to resolve the URL:\n\n%@", error]];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];

    [self updateStatus:@"URL resolution failed"];
}

- (void)ytdlpBackendDidCancel:(YTDLPBackend *)backend
{
    NSLog( @"[Player] ytdlpBackendDidCancel");

    [progressIndicator setHidden:YES];
    [progressIndicator stopAnimation:self];
    [self updateStatus:@"URL resolution cancelled"];
}

#pragma mark - StreamPlayerDelegate

- (void)streamPlayerDidStartPlaying:(StreamPlayer *)player
{
    NSLog(@"[Player] StreamPlayer started playing");
    [playButton setEnabled:YES];
    [stopButton setEnabled:YES];
    [self updateStatus:@"Streaming..."];
}

- (void)streamPlayerDidStop:(StreamPlayer *)player
{
    NSLog(@"[Player] StreamPlayer stopped");

    // Auto-advance for local video files when the stream ends naturally
    if (playerMode == PlayerModeLocal && _usingStreamPlayer) {
        [self stopPlayback];
        if ([playlist count] > 1) {
            if (repeatEnabled || shuffleEnabled) {
                [self nextTrack:self];
            } else {
                int nextIdx = currentIndex + 1;
                if (nextIdx < (int)[playlist count]) {
                    [self playFromPlaylistAtIndex:nextIdx];
                }
            }
        } else if (repeatEnabled && [playlist count] == 1) {
            [self playFromPlaylistAtIndex:0];
        }
    }
}

- (void)streamPlayer:(StreamPlayer *)player didFailWithError:(NSError *)error
{
    NSLog(@"[Player] StreamPlayer error: %@", [error localizedDescription]);
    [self updateStatus:[NSString stringWithFormat:@"Stream error: %@",
                       [error localizedDescription]]];
}

- (void)streamPlayer:(StreamPlayer *)player didDiscoverVideoWithWidth:(int)width
              height:(int)height
{
    NSLog(@"[Player] StreamPlayer discovered video: %dx%d", width, height);
    [videoView setHidden:NO];
    [flowView setHidden:YES];
}

- (void)streamPlayer:(StreamPlayer *)player didDecodeVideoFrameData:(NSData *)rgbData
              width:(int)width height:(int)height
{
    NSLog(@"[Player] video frame received: %dx%d, dataLen=%tu, videoView.hidden=%d videoView.frame=%@",
          width, height, [rgbData length],
          [videoView isHidden], NSStringFromRect([videoView frame]));
    [_videoRenderView setFrameData:rgbData width:width height:height];

    // Force immediate synchronous drawing on the video render view
    [_videoRenderView display];
    [[videoView window] flushWindow];
}

#pragma mark - RadioManagerDelegate

- (void)radioManagerDidUpdateStations:(RadioManager *)manager
{
    [flowView reloadData];
    NSUInteger count = [[manager stations] count];
    if (count > 0) {
        // Load text-placeholder textures for visible stations immediately
        NSMutableIndexSet *indices = [NSMutableIndexSet indexSet];
        NSUInteger loadCount = MIN(24, count);
        for (NSUInteger i = 0; i < loadCount; i++) {
            [indices addIndex:i];
        }
        [flowView updateTexturesForIndices:indices];

        // Pin the first station so the menu checkmark has a default
        RadioStation *firstStation = [[manager stations] objectAtIndex:0];
        if (_pendingRadioStation != firstStation) {
            [_pendingRadioStation release];
            _pendingRadioStation = [firstStation retain];
        }
        // Scroll flowView to the first item without triggering playback
        _suppressFlowSelection = YES;
        [flowView setSelectedIndex:0];
        _suppressFlowSelection = NO;

        [previousButton setEnabled:(count > 1)];
        [nextButton setEnabled:(count > 1)];
    }
    // Rebuild the dynamic station list in the Radio menu
    [self rebuildRadioStationMenu];
}

- (void)radioManagerDidStartPlaying:(RadioManager *)manager station:(RadioStation *)station
{
    [playButton setImage:[self iconPause]];
    [radioTextLabel setStringValue:@""];  // Clear previous radio text
    if (station) {
        [statusLabel setStringValue:[NSString stringWithFormat:@"Now Playing: %@", [station name]]];
        [mainWindow setTitle:[NSString stringWithFormat:@"Player - %@", [station name]]];
        // Keep the flow view in sync
        NSArray *stations = [manager stations];
        NSUInteger idx = [stations indexOfObject:station];
        if (idx != NSNotFound) {
            _suppressFlowSelection = YES;
            [flowView setSelectedIndex:idx];
            _suppressFlowSelection = NO;
        }
    } else {
        [statusLabel setStringValue:@"Now Playing"];
        [mainWindow setTitle:@"Player - Internet Radio"];
    }
    [stopButton setEnabled:YES];
    [self rebuildRadioStationMenu];
}

- (void)radioManagerDidStop:(RadioManager *)manager
{
    [playButton setImage:[self iconPlay]];
    [stopButton setEnabled:NO];
    [radioTextLabel setStringValue:@""];
    NSString *name = [manager currentStationName];
    if (name) {
        [statusLabel setStringValue:[NSString stringWithFormat:@"Stopped: %@", name]];
    } else {
        [statusLabel setStringValue:@"Stopped"];
    }
}

- (void)radioManager:(RadioManager *)manager didFailWithError:(NSString *)errorMessage
{
    [statusLabel setStringValue:[NSString stringWithFormat:@"Error: %@", errorMessage]];
    [playButton setImage:[self iconPlay]];
}

- (void)radioManagerDidUpdateStatus:(RadioManager *)manager status:(NSString *)status
{
    if ([status length] > 0) {
        [statusLabel setStringValue:status];
    }
}

- (void)radioManager:(RadioManager *)manager didUpdateRadioText:(NSString *)radioText
{
    if ([radioText length] > 0) {
        [radioTextLabel setStringValue:radioText];
    } else {
        [radioTextLabel setStringValue:@""];
    }
}

- (void)radioManager:(RadioManager *)manager didUpdateMetadata:(NSDictionary *)metadata
{
    // Build a multiline display: StreamTitle on first line, icy-url on second
    NSString *streamTitle = [metadata objectForKey:@"StreamTitle"] ?: @"";
    NSString *icyURL = [metadata objectForKey:@"icy-url"] ?: @"";
    NSString *display = @"";
    if ([streamTitle length] > 0) {
        display = streamTitle;
    }
    if ([icyURL length] > 0) {
        if ([display length] > 0) {
            display = [display stringByAppendingFormat:@"\nicy-url: %@", icyURL];
        } else {
            display = [NSString stringWithFormat:@"icy-url: %@", icyURL];
        }
    }
    [radioTextLabel setStringValue:display];
}

- (void)radioManager:(RadioManager *)manager didLoadIconAtIndex:(NSUInteger)index
{
    // Incrementally update the ItemFlowView texture for this index
    [flowView updateTexturesForIndices:[NSIndexSet indexSetWithIndex:index]];
}

#pragma mark - Radio Mode: Dynamic Station Menu

- (void)rebuildRadioStationMenu
{
    NSMenu *radioMenu = [[[NSApp mainMenu] itemWithTitle:@"Radio"] submenu];
    if (!radioMenu) return;

    // Remove all dynamically-added items (keep indices 0-3: Browse, Open, sep, Stop)
    while ([radioMenu numberOfItems] > 4) {
        [radioMenu removeItemAtIndex:[radioMenu numberOfItems] - 1];
    }

    // Add sentinel separator
    NSMenuItem *stationSep = (NSMenuItem *)[NSMenuItem separatorItem];
    [stationSep setTag:9999];
    [radioMenu addItem:stationSep];

    // Add station items
    RadioManager *rm = [RadioManager sharedManager];
    NSString *currentName = [rm currentStationName] ?: [_pendingRadioStation name];
    NSArray *stations = [rm stations];
    for (NSUInteger si = 0; si < [stations count]; si++) {
        RadioStation *station = [stations objectAtIndex:si];
        NSString *name = [station name] ?: @"Unknown Station";
        NSMenuItem *sItem = [[NSMenuItem alloc] initWithTitle:name
                                                       action:@selector(radioSelectStationFromMenu:)
                                                keyEquivalent:@""];
        [sItem setTarget:self];
        [sItem setRepresentedObject:station];
        if (currentName && [[station name] isEqualToString:currentName]) {
            [sItem setState:NSOnState];
        }
        [radioMenu addItem:sItem];
        [sItem release];
    }
}

- (void)radioSelectStationFromMenu:(id)sender
{
    RadioStation *station = [sender representedObject];
    if (!station) return;

    // Ensure we're in radio mode
    if (playerMode != PlayerModeRadio) {
        [self enterRadioMode];
    }

    // Scroll the flow view to match, but don't trigger selection delegate
    _suppressFlowSelection = YES;
    NSArray *stations = [[RadioManager sharedManager] stations];
    NSUInteger idx = [stations indexOfObject:station];
    if (idx != NSNotFound) {
        [flowView setSelectedIndex:idx];
    }
    _suppressFlowSelection = NO;

    // Play the station
    [self schedulePlayStation:station];
}

#pragma mark - Radio Mode: URL History

- (void)addRadioURLToHistory:(NSString *)url
{
    // RadioManager could persist history in the future
}

@end
