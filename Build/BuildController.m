/*
 * Copyright 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BuildController.h"
#import "GWBuildPreflight.h"
#import <PackageManager/GWHeaderDatabase.h>
#import <PackageManager/GWPackageManager.h>
#include <dlfcn.h>

/* Label colors: identical to the GSFileLabel / DSStoreLabelColor encodings
 * used by the Workspace stack (1=Red .. 7=Grey).  The classes that apply
 * them (GSFileMetadata, DSStore) live in libGSMetadata / libDSStore and are
 * loaded with dlopen() at runtime, so Build.app has no build-time dependency
 * on those libraries or their headers.  The local class declarations below
 * only exist so the compiler can emit the message sends; the real classes are
 * resolved by the ObjC runtime once the libraries are loaded. */
typedef NS_ENUM(NSInteger, GWBuildFileLabel) {
    GWBuildFileLabelNone   = 0,
    GWBuildFileLabelRed    = 1,
    GWBuildFileLabelOrange = 2,
    GWBuildFileLabelYellow = 3,
    GWBuildFileLabelGreen  = 4,
    GWBuildFileLabelBlue   = 5,
    GWBuildFileLabelPurple = 6,
    GWBuildFileLabelGrey   = 7,
};

@interface GSFileMetadata : NSObject
+ (instancetype)metadataForFileAtPath:(NSString *)path;
- (void)setLabelNumber:(NSInteger)label;
- (BOOL)writeToFileAtPath:(NSString *)path error:(NSError **)error;
@end

@interface DSStore : NSObject
+ (instancetype)storeWithPath:(NSString *)path;
+ (instancetype)createStoreAtPath:(NSString *)path withEntries:(NSArray *)entries;
- (BOOL)load;
- (BOOL)save;
- (void)setLabelColorForFilename:(NSString *)filename color:(NSInteger)color;
@end

#pragma mark - Tool path resolution

static NSString *toolPath(NSString *name)
{
    NSString *p = [NSTask launchPathForTool:name];
    if (p) return p;
    NSArray *dirs = @[@"/usr/local/bin", @"/usr/local/sbin",
                       @"/usr/bin", @"/bin", @"/usr/sbin", @"/sbin"];
    for (NSString *dir in dirs) {
        p = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p])
            return p;
    }
    return nil;
}

#pragma mark - Background queue

dispatch_queue_t buildQueue(void)
{
    static dispatch_queue_t _buildQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _buildQueue = dispatch_queue_create("Build.buildQueue", DISPATCH_QUEUE_SERIAL);
    });
    return _buildQueue;
}

#pragma mark - Metrics (from AppearanceMetrics.h)

static const CGFloat kWinWidth = 400.0;
static const CGFloat kSideMargin = 24.0;
static const CGFloat kBottomMargin = 20.0;
static const CGFloat kBtnHeight = 20.0;
static const CGFloat kBtnWide = 100.0;
static const CGFloat kBarHeight = 20.0;
static const CGFloat kLineHeight = 18.0;
static const CGFloat kIconSide = 64.0;
static const CGFloat kIconLeft = 24.0;
static const CGFloat kTextLeft = 104.0;
static const CGFloat kTopMargin = 15.0;
static const CGFloat kSpace8 = 8.0;
static const CGFloat kSpace16 = 16.0;

#pragma mark - BWLogWindowController

@interface BWLogWindowController ()
{
    NSScrollView *_scrollView;
    NSTextView *_logView;
}
- (void)appendLog:(NSString *)text;
- (void)clearLog;
@end

@implementation BWLogWindowController

- (instancetype)init
{
    NSRect screenFrame = NSMakeRect(0, 0, 800, 600);
    NSScreen *screen = [NSScreen mainScreen];
    if (screen) {
        screenFrame = [screen frame];
    }
    CGFloat logHeight = screenFrame.size.height / 4.0;
    NSRect logFrame = NSMakeRect(screenFrame.origin.x,
                                  screenFrame.origin.y,
                                  screenFrame.size.width,
                                  logHeight);
    NSWindow *logWindow = [[NSWindow alloc]
        initWithContentRect:logFrame
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                           | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:YES];
    [logWindow setTitle:NSLocalizedString(@"Build Log", @"Title of the build log window")];
    [logWindow setMinSize:NSMakeSize(400, 100)];

    self = [super initWithWindow:logWindow];
    if (self)
    {
        NSView *contentView = [logWindow contentView];
        NSRect frame = [contentView bounds];

        _scrollView = [[NSScrollView alloc] initWithFrame:frame];
        [_scrollView setHasVerticalScroller:YES];
        [_scrollView setHasHorizontalScroller:NO];
        [_scrollView setBorderType:NSNoBorder];
        [_scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        NSSize contentSize = [_scrollView contentSize];
        _logView = [[NSTextView alloc]
            initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
        [_logView setMinSize:NSMakeSize(0.0, contentSize.height)];
        [_logView setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
        [_logView setVerticallyResizable:YES];
        [_logView setHorizontallyResizable:NO];
        [_logView setEditable:NO];
        [_logView setSelectable:YES];
        [_logView setFont:[NSFont userFixedPitchFontOfSize:10]];
        [_logView setTextColor:[NSColor darkGrayColor]];
        [_logView setBackgroundColor:[NSColor whiteColor]];
        [[_logView textContainer] setContainerSize:NSMakeSize(contentSize.width, FLT_MAX)];
        [[_logView textContainer] setWidthTracksTextView:YES];

        [_scrollView setDocumentView:_logView];
        [contentView addSubview:_scrollView];
    }
    return self;
}

- (void)appendLog:(NSString *)text
{
    if (!text || !_logView) return;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont userFixedPitchFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor darkGrayColor]
    };
    NSAttributedString *astr = [[NSAttributedString alloc] initWithString:text
                                                               attributes:attrs];
    [[_logView textStorage] appendAttributedString:astr];
    [_logView scrollRangeToVisible:NSMakeRange([[_logView string] length], 0)];
}

- (void)clearLog
{
    if (!_logView) return;
    [[_logView textStorage] replaceCharactersInRange:
        NSMakeRange(0, [[_logView string] length]) withString:@""];
}

@end

#pragma mark - BuildController

@interface BuildController ()
@property (strong, nonatomic) NSArray *blacklist;
@property (strong, nonatomic) NSDictionary *gnustepInfo;
@property (strong) NSString *pendingLibrary;
@property (assign) BOOL headerInstallOffered;
@property (assign) BOOL preflightInstalledPackages;
- (BOOL)isItemBlacklisted:(NSString *)item;
@end

@implementation BuildController

@synthesize makefilePath;
@synthesize closeCount;
@synthesize closeTimer;
@synthesize logController = _logController;

- (id)init
{
    self = [super init];
    if (self) {
        self.buildOutput = [[NSMutableString alloc] init];
        self.consoleMode = NO;
        _logController = [[BWLogWindowController alloc] init];
        [[_logController window] setDelegate:self];
    }
    return self;
}

/* Build's main menu is set once at application startup (see
 * BuildApplication applicationDidFinishLaunching), so every window - the
 * catalog and the build workflow alike - has a working menu bar with the
 * standard Cmd+Q quit.  Menu auto-validation is disabled so the items are
 * never greyed out; the actions are standard responder-chain actions. */
+ (void)setupMainMenu
{
    if ([NSApp mainMenu] != nil) return;   /* built once in applicationDidFinishLaunching */

    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    [mainMenu setAutoenablesItems:NO];

    /* Application Menu */
    NSString *appName = [[NSProcessInfo processInfo] processName];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:appName
                                                         action:nil
                                                  keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    [appMenu addItemWithTitle:NSLocalizedString(@"About", @"About menu item")
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:NSLocalizedString(@"Quit", @"Quit menu item")
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];

    /* Edit Menu */
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit", @"Edit menu title")
                                                          action:nil
                                                   keyEquivalent:@""];
    [mainMenu addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Edit", @"Edit menu title")];
    [editMenu addItemWithTitle:NSLocalizedString(@"Undo", @"Undo menu item") action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Redo", @"Redo menu item") action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:NSLocalizedString(@"Cut", @"Cut menu item") action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Copy", @"Copy menu item") action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Paste", @"Paste menu item") action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Select All", @"Select All menu item") action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];

    /* Window Menu */
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Window", @"Window menu title")
                                                           action:nil
                                                    keyEquivalent:@""];
    [mainMenu addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Window", @"Window menu title")];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Minimize", @"Minimize menu item")
                          action:@selector(performMiniaturize:)
                   keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Zoom", @"Zoom menu item")
                          action:@selector(performZoom:)
                   keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Build Log", @"Build Log menu item")
                          action:@selector(showLog:)
                   keyEquivalent:@"l"];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Bring All to Front", @"Bring All to Front menu item")
                          action:@selector(arrangeInFront:)
                   keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Close", @"Close menu item")
                          action:@selector(performClose:)
                   keyEquivalent:@"w"];
    [windowMenuItem setSubmenu:windowMenu];
    [NSApp setWindowsMenu:windowMenu];

    [NSApp setMainMenu:mainMenu];
}

- (void)createProgressWindow
{
    if (_window) return;

    CGFloat contentW = kWinWidth - 2 * kSideMargin;
    CGFloat btnRight = kWinWidth - kSideMargin;
    CGFloat textW = contentW - (kTextLeft - kSideMargin);
    NSString *name = [self displayNameFromMakefile];

    CGFloat winH = kBottomMargin + kBtnHeight + kSpace16
                 + kBarHeight + kSpace8
                 + kLineHeight + kSpace8
                 + kIconSide
                 + kTopMargin;

    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWinWidth, winH)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskMiniaturizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];

    CGFloat y = kBottomMargin;

    /* Cancel button (lower-right) */
    CGFloat cancelX = btnRight - kBtnWide;
    _cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(cancelX, y, kBtnWide, kBtnHeight)];
    [_cancelButton setTitle:NSLocalizedString(@"Cancel", @"Cancel button")];
    [_cancelButton setTarget:self];
    [_cancelButton setAction:@selector(cancelClicked:)];
    [_cancelButton setKeyEquivalent:@"\e"];
    // The Cancel button is always active: it terminates a running build or
    // install task, and is a harmless no-op otherwise.
    [[_window contentView] addSubview:_cancelButton];

    y += kBtnHeight + kSpace16;

    /* Progress bar */
    _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(kTextLeft, y, textW, kBarHeight)];
    [_progressBar setStyle:NSProgressIndicatorBarStyle];
    [_progressBar setIndeterminate:NO];
    [_progressBar setMinValue:0.0];
    [_progressBar setMaxValue:100.0];
    [_progressBar setDoubleValue:0.0];
    [[_window contentView] addSubview:_progressBar];

    y += kBarHeight + kSpace8;

    /* Status field */
    _statusField = [[NSTextField alloc] initWithFrame:NSMakeRect(kTextLeft, y, textW, kLineHeight)];
    [_statusField setStringValue:name ? [NSString stringWithFormat:NSLocalizedString(@"Building %@…", @"Status: building a named app"), name] : NSLocalizedString(@"Building…", @"Status: building (no name)")];
    [_statusField setBezeled:NO];
    [_statusField setDrawsBackground:NO];
    [_statusField setEditable:NO];
    [_statusField setSelectable:NO];
    [_statusField setAlignment:NSTextAlignmentLeft];
    [_statusField setFont:[NSFont systemFontOfSize:11.0]];
    [[_window contentView] addSubview:_statusField];

    y += kLineHeight + kSpace8;

    /* Icon and app name */
    _iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(kIconLeft, y, kIconSide, kIconSide)];
    [_iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
    NSImage *icon = [self productIconFromMakefile];
    if (!icon) {
        icon = [[NSWorkspace sharedWorkspace] iconForFileType:@"app"];
    }
    if (icon) {
        NSLog(@"icon: loaded size=%@ reps=%ld", NSStringFromSize([icon size]), [[icon representations] count]);
        // Convert to a new image to avoid display issues with certain rep types
        NSImage *displayIcon = [[NSImage alloc] initWithSize:NSMakeSize(kIconSide, kIconSide)];
        [displayIcon lockFocus];
        [icon drawInRect:NSMakeRect(0, 0, kIconSide, kIconSide)
                fromRect:NSZeroRect
               operation:NSCompositeSourceOver
                fraction:1.0];
        [displayIcon unlockFocus];
        [_iconView setImage:displayIcon];
    }
    [[_window contentView] addSubview:_iconView];

    if (name) {
        _nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(kTextLeft, y + (kIconSide - kLineHeight) / 2, textW, kLineHeight)];
        [_nameField setStringValue:name];
        [_nameField setBezeled:NO];
        [_nameField setDrawsBackground:NO];
        [_nameField setEditable:NO];
        [_nameField setSelectable:NO];
        [_nameField setFont:[NSFont systemFontOfSize:13.0]];
        [[_window contentView] addSubview:_nameField];
    }

    [_window setTitle:name ? name : NSLocalizedString(@"Build", @"Window title")];
    [_window setDelegate:self];
    [_window center];
    [_window orderFront:nil];
}

- (void)showWindow
{
    NSLog(@"showWindow: DISPLAY=%s makefilePath=%@", getenv("DISPLAY"), makefilePath);
    if (!getenv("DISPLAY")) {
        if (makefilePath) {
            [self startBuild];
        }
        return;
    }

    NSLog(@"showWindow: calling setupMenu");
    [BuildController setupMainMenu];

    if (makefilePath) {
        NSLog(@"showWindow: calling createProgressWindow");
        [self createProgressWindow];
        NSLog(@"showWindow: calling startBuild");
        [self startBuild];
    } else {
        [self showFileOpenDialog];
    }
}

- (void)showProgressWindow
{
    NSLog(@"showProgressWindow: DISPLAY=%s makefilePath=%@", getenv("DISPLAY"), makefilePath);
    if (!getenv("DISPLAY")) {
        return;
    }

    NSLog(@"showProgressWindow: calling setupMenu");
    [BuildController setupMainMenu];

    NSLog(@"showProgressWindow: calling createProgressWindow");
    [self createProgressWindow];
}

- (void)hideProgressWindow
{
    if (_window) {
        [_window orderOut:nil];
    }
}

- (void)reloadIcon
{
    if (!_iconView) return;
    NSImage *icon = [self productIconFromMakefile];
    if (!icon) {
        icon = [[NSWorkspace sharedWorkspace] iconForFileType:@"app"];
    }
    if (icon) {
        NSImage *displayIcon = [[NSImage alloc] initWithSize:NSMakeSize(kIconSide, kIconSide)];
        [displayIcon lockFocus];
        [icon drawInRect:NSMakeRect(0, 0, kIconSide, kIconSide)
                fromRect:NSZeroRect
               operation:NSCompositeSourceOver
                fraction:1.0];
        [displayIcon unlockFocus];
        [_iconView setImage:displayIcon];
    }
}

#pragma mark - Actions

- (void)cancelClicked:(id)sender
{
    if (buildTask && [buildTask isRunning]) {
        [buildTask terminate];
    }
    if (installTask && [installTask isRunning]) {
        [installTask terminate];
    }
    // Cancelling aborts the build/install, so mark the project as failed and
    // quit the app cleanly, whether a task was running or not.
    [self setProjectLabel:GWBuildFileLabelRed];
    [self quitCleanly];
}

- (void)showLog:(id)sender
{
    NSLog(@"showLog: called");
    if (!_logController) {
        NSLog(@"showLog: _logController is nil");
        return;
    }
    NSWindow *logWin = [_logController window];
    if (!logWin) {
        NSLog(@"showLog: logWin is nil");
        return;
    }
    NSLog(@"showLog: ordering front log window %@", logWin);
    dispatch_async(dispatch_get_main_queue(), ^{
        [logWin orderFront:nil];
        [logWin makeKeyWindow];
        NSLog(@"showLog: window shown");
    });
    NSLog(@"showLog: done (deferred)");
}

#pragma mark - Build

- (BOOL)runSyncTask:(NSString *)launchPath arguments:(NSArray *)args
           directory:(NSString *)dir logPrefix:(NSString *)prefix
{
    NSTask *task = [[NSTask alloc] init];
    [task setCurrentDirectoryPath:dir];
    [task setLaunchPath:launchPath];
    [task setArguments:args];
    [task setEnvironment:[[NSProcessInfo processInfo] environment]];

    NSPipe *pipe = [[NSPipe alloc] init];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];

    NSString *log = [NSString stringWithFormat:@"=== %@ ===\n", prefix];
    dispatch_async(dispatch_get_main_queue(), ^{
        [_logController appendLog:log];
    });
    write(STDOUT_FILENO, [log UTF8String], [log length]);

    @try {
        [task launch];

        NSFileHandle *handle = [pipe fileHandleForReading];
        while ([task isRunning]) {
            NSData *data = [handle availableData];
            if ([data length] > 0) {
                NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                [self.buildOutput appendString:outStr];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [_logController appendLog:outStr];
                });
                write(STDOUT_FILENO, [data bytes], [data length]);
            }
        }
        // Read remaining data
        NSData *remaining = [handle readDataToEndOfFile];
        if ([remaining length] > 0) {
            NSString *outStr = [[NSString alloc] initWithData:remaining encoding:NSUTF8StringEncoding];
            [self.buildOutput appendString:outStr];
            dispatch_async(dispatch_get_main_queue(), ^{
                [_logController appendLog:outStr];
            });
            write(STDOUT_FILENO, [remaining bytes], [remaining length]);
        }

        return [task terminationStatus] == 0;
    } @catch (NSException *exception) {
        NSString *err = [NSString stringWithFormat:@"%@ failed: %@\n", prefix, [exception reason]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [_logController appendLog:err];
        });
        write(STDOUT_FILENO, [err UTF8String], [err length]);
        return NO;
    }
}

- (NSString *)resolveMakePath
{
    NSString *path = toolPath(@"gmake");
    return path ?: toolPath(@"make");
}

/* Look under both Libraries/ and libs/ for library GNUmakefiles */
- (NSArray *)libraryMakefilesInRepoRoot:(NSString *)repoRoot
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *result = [NSMutableArray array];

    for (NSString *dirName in @[@"Libraries", @"libs"])
    {
        NSString *libsDir = [repoRoot stringByAppendingPathComponent:dirName];
        NSArray *contents = [fm contentsOfDirectoryAtPath:libsDir error:NULL];
        for (NSString *item in contents)
        {
            NSString *mf = [libsDir stringByAppendingPathComponent:item];
            mf = [mf stringByAppendingPathComponent:@"GNUmakefile"];
            if ([fm fileExistsAtPath:mf])
                [result addObject:mf];
        }
    }
    return result;
}

- (NSString *)findRepoRootFromMakefileDir:(NSString *)makefileDir buildDir:(NSString *)buildDir
{
    /* For catalog builds, buildDir is the clone root */
    if (buildDir && [[self libraryMakefilesInRepoRoot:buildDir] count] > 0)
        return buildDir;

    /* Walk up from the makefile directory looking for Libraries/, libs/, or .git */
    NSString *candidate = makefileDir;
    NSFileManager *fm = [NSFileManager defaultManager];
    while (candidate && [candidate length] > 1)
    {
        if ([[self libraryMakefilesInRepoRoot:candidate] count] > 0
            || [fm fileExistsAtPath:[candidate stringByAppendingPathComponent:@".git"]])
            return candidate;
        candidate = [candidate stringByDeletingLastPathComponent];
    }
    return nil;
}

- (void)buildLibraryDependenciesInDirectory:(NSString *)directory makePath:(NSString *)makePath repoRoot:(NSString *)repoRoot
{
    if (!repoRoot)
        repoRoot = [self findRepoRootFromMakefileDir:directory buildDir:self.buildDir];
    if (!repoRoot)
        return;

    NSArray *libMakefiles = [self libraryMakefilesInRepoRoot:repoRoot];
    if ([libMakefiles count] == 0)
        return;

    for (NSString *fullLibPath in libMakefiles)
    {
        NSString *libDir = [fullLibPath stringByDeletingLastPathComponent];
        NSString *libName = [[libDir lastPathComponent] stringByDeletingPathExtension];
        NSString *logMsg = [NSString stringWithFormat:@"=== Building library: %@ ===\n", libName];
        [self.buildOutput appendString:logMsg];
        [_logController appendLog:logMsg];
        write(STDOUT_FILENO, [logMsg UTF8String], [logMsg length]);

        NSTask *libTask = [[NSTask alloc] init];
        [libTask setCurrentDirectoryPath:libDir];
        [libTask setLaunchPath:makePath];
        [libTask setArguments:@[@"-f", fullLibPath, @"clean", @"all"]];
        [libTask setEnvironment:[[NSProcessInfo processInfo] environment]];

        NSPipe *libPipe = [[NSPipe alloc] init];
        [libTask setStandardOutput:libPipe];
        [libTask setStandardError:libPipe];

        @try {
            [libTask launch];

            NSFileHandle *handle = [libPipe fileHandleForReading];
            while ([libTask isRunning]) {
                NSData *data = [handle availableData];
                if ([data length] > 0) {
                    NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    [self.buildOutput appendString:outStr];
                    [_logController appendLog:outStr];
                    write(STDOUT_FILENO, [data bytes], [data length]);
                }
            }
            NSData *remaining = [handle readDataToEndOfFile];
            if ([remaining length] > 0) {
                NSString *outStr = [[NSString alloc] initWithData:remaining encoding:NSUTF8StringEncoding];
                [self.buildOutput appendString:outStr];
                [_logController appendLog:outStr];
                write(STDOUT_FILENO, [remaining bytes], [remaining length]);
            }
        } @catch (NSException *e) {
            NSString *errMsg = [NSString stringWithFormat:@"Failed to build library %@: %@\n", libName, [e reason]];
            [self.buildOutput appendString:errMsg];
            [_logController appendLog:errMsg];
            write(STDOUT_FILENO, [errMsg UTF8String], [errMsg length]);
            return;
        }

        if ([libTask terminationStatus] != 0) {
            NSString *errMsg = [NSString stringWithFormat:@"Library %@ build failed with status %d\n", libName, [libTask terminationStatus]];
            [self.buildOutput appendString:errMsg];
            [_logController appendLog:errMsg];
            write(STDOUT_FILENO, [errMsg UTF8String], [errMsg length]);
            return;
        }

        NSTask *libInstallTask = [[NSTask alloc] init];
        [libInstallTask setCurrentDirectoryPath:libDir];
        [libInstallTask setLaunchPath:makePath];
        [libInstallTask setArguments:@[@"-f", fullLibPath, @"install"]];
        [libInstallTask setEnvironment:[[NSProcessInfo processInfo] environment]];
        @try {
            [libInstallTask launch];
            [libInstallTask waitUntilExit];
        } @catch (NSException *e) {
            NSString *errMsg = [NSString stringWithFormat:@"Failed to install library %@: %@\n", libName, [e reason]];
            [self.buildOutput appendString:errMsg];
            [_logController appendLog:errMsg];
            return;
        }

        NSString *doneMsg = [NSString stringWithFormat:@"=== Library %@ built and installed ===\n", libName];
        [self.buildOutput appendString:doneMsg];
        [_logController appendLog:doneMsg];
        write(STDOUT_FILENO, [doneMsg UTF8String], [doneMsg length]);
    }
}

- (void)runPrebuildStepsInDirectory:(NSString *)directory
                     forceConfigure:(BOOL)forceConfigure
{
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. autoreconf if needed
    BOOL needsAutoreconf = NO;
    NSString *configureAc = [directory stringByAppendingPathComponent:@"configure.ac"];
    NSString *configureIn = [directory stringByAppendingPathComponent:@"configure.in"];
    NSString *configure = [directory stringByAppendingPathComponent:@"configure"];
    NSString *makefileIn = [directory stringByAppendingPathComponent:@"GNUmakefile.in"];

    if ([fm fileExistsAtPath:configureAc] || [fm fileExistsAtPath:configureIn]) {
        NSString *src = [fm fileExistsAtPath:configureAc] ? configureAc : configureIn;
        if (![fm fileExistsAtPath:configure]) {
            needsAutoreconf = YES;
        } else {
            NSDictionary *srcAttr = [fm attributesOfItemAtPath:src error:NULL];
            NSDictionary *cfgAttr = [fm attributesOfItemAtPath:configure error:NULL];
            if (srcAttr && cfgAttr &&
                [[srcAttr fileModificationDate] laterDate:[cfgAttr fileModificationDate]] == [srcAttr fileModificationDate]) {
                needsAutoreconf = YES;
            }
        }
    }

    if (needsAutoreconf) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_statusField) [_statusField setStringValue:NSLocalizedString(@"Running autoreconf…", @"Status: running autoreconf")];
        });
        NSString *autoreconfPath = toolPath(@"autoreconf");
        if (autoreconfPath) {
            BOOL ok = [self runSyncTask:autoreconfPath
                              arguments:@[@"-i"]
                              directory:directory
                              logPrefix:@"autoreconf"];
            if (!ok) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (_statusField) [_statusField setStringValue:NSLocalizedString(@"autoreconf failed", @"Status: autoreconf failed")];
                });
                return;
            }
        }
    }

    // 2. Run configure if present (checks GNUmakefile.in and other .in files)
    if ([fm fileExistsAtPath:makefileIn] || [self hasInFiles:directory]) {
        // If GNUmakefile.in exists but no GNUmakefile yet (or .in is newer), run configure
        NSString *makefilePathLocal = [directory stringByAppendingPathComponent:@"GNUmakefile"];
        BOOL needsConfigure = ![fm fileExistsAtPath:makefilePathLocal];
        if (!needsConfigure) {
            NSDictionary *inAttr = [fm attributesOfItemAtPath:makefileIn error:NULL];
            NSDictionary *mkAttr = [fm attributesOfItemAtPath:makefilePathLocal error:NULL];
            if (inAttr && mkAttr &&
                [[inAttr fileModificationDate] laterDate:[mkAttr fileModificationDate]] == [inAttr fileModificationDate]) {
                needsConfigure = YES;
            }
        }
        // Force a re-configure after the package preflight installed new
        // packages: the earlier configure ran before those headers / tools
        // were present, so its output may be stale.
        if (forceConfigure) needsConfigure = YES;
        if (needsConfigure) {
            if ([fm isExecutableFileAtPath:configure]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (_statusField) [_statusField setStringValue:NSLocalizedString(@"Running configure…", @"Status: running configure")];
                });
                [self runSyncTask:configure
                        arguments:@[]
                        directory:directory
                        logPrefix:@"configure"];
            } else if ([fm fileExistsAtPath:configure]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (_statusField) [_statusField setStringValue:NSLocalizedString(@"Running configure (sh)…", @"Status: running configure via sh")];
                });
                [self runSyncTask:@"/bin/sh"
                        arguments:@[configure]
                        directory:directory
                        logPrefix:@"configure"];
            }
        }
    }
}

- (BOOL)hasInFiles:(NSString *)directory
{
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
    for (NSString *name in contents) {
        if ([name hasSuffix:@".in"] && ![[name lastPathComponent] hasPrefix:@"."]) {
            return YES;
        }
    }
    return NO;
}

- (void)startBuild
{
    [self.buildOutput setString:@""];
    [_logController clearLog];

    if (!makefilePath) {
        if (_statusField) [_statusField setStringValue:NSLocalizedString(@"Error: No GNUmakefile specified", @"Status: no makefile given")];
        else fprintf(stderr, "Error: No GNUmakefile specified\n");
        return;
    }

    if (![makefilePath hasPrefix:@"/"]) {
        NSString *currentDir = [[NSFileManager defaultManager] currentDirectoryPath];
        makefilePath = [currentDir stringByAppendingPathComponent:makefilePath];
        makefilePath = [makefilePath stringByStandardizingPath];
        self.makefilePath = makefilePath;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:makefilePath]) {
        NSString *msg = [NSString stringWithFormat:@"Error: GNUmakefile not found: %@", makefilePath];
        if (_statusField) [_statusField setStringValue:msg];
        else fprintf(stderr, "%s\n", [msg UTF8String]);
        return;
    }

    NSString *directory = [makefilePath stringByDeletingLastPathComponent];
    if ([directory length] == 0) directory = @".";

    // If source is read-only, copy to a temp directory for building
    if (access([directory UTF8String], W_OK) != 0) {
        NSString *template = @"/tmp/Build-XXXXXXXX";
        char *tmpPath = strdup([template UTF8String]);
        if (mkdtemp(tmpPath)) {
            _objDir = [[NSString stringWithUTF8String:tmpPath] stringByStandardizingPath];

            if (_statusField) [_statusField setStringValue:NSLocalizedString(@"Copying source to temp directory…", @"Status: copying source files")];

            NSTask *cpTask = [[NSTask alloc] init];
            [cpTask setLaunchPath:toolPath(@"cp")];
            [cpTask setArguments:@[@"-a", directory, _objDir]];
            [cpTask launch];
            [cpTask waitUntilExit];

            NSString *srcName = [directory lastPathComponent];
            NSString *destDir = [_objDir stringByAppendingPathComponent:srcName];
            directory = destDir;
            makefilePath = [destDir stringByAppendingPathComponent:
                [makefilePath lastPathComponent]];
            self.makefilePath = makefilePath;
        }
        free(tmpPath);
    }

    NSString *makePath = [self resolveMakePath];
    if (!makePath) {
        if (_statusField) [_statusField setStringValue:NSLocalizedString(@"Error: neither gmake nor make found in PATH", @"Status: make tool not found")];
        else fprintf(stderr, "Error: neither gmake nor make found in PATH\n");
        return;
    }

    // Initialize per-project progress tracking
    _projectFileCounts = [[NSMutableArray alloc] init];
    _projectCompiledCounts = [[NSMutableArray alloc] init];
    _currentProjectIndex = -1;

    if (_progressBar) {
        [_progressBar setIndeterminate:YES];
        [_progressBar startAnimation:nil];
    }

    [self runPrebuildStepsInDirectory:directory forceConfigure:NO];

    // Install missing system headers before resolving GNUstep dependencies,
    // so the build does not fail on a missing <gphoto2/gphoto2.h>.
    if (![self runPackagePreflightInDirectory:directory]) {
        return;
    }

    // The prebuild steps above ran before any packages were installed, so
    // configure may have missed headers / tools the packages now provide.
    // Re-run configure so its output reflects the fresh environment.
    if (self.preflightInstalledPackages) {
        [self runPrebuildStepsInDirectory:directory forceConfigure:YES];
    }

    // Resolve GNUstep dependencies before building
    [self resolveDependenciesBeforeBuildInDirectory:directory];

    // Build bundled Libraries/ from the same repo (detected automatically)
    [self buildLibraryDependenciesInDirectory:directory makePath:makePath repoRoot:nil];

    // Add main project as last progress segment
    NSString *mainTarget = [self productNameFromMakefile];
    NSInteger mainCount = [self countSourceFilesInMakefile:makefilePath
                                                    target:mainTarget
                                                     depth:0];
    [_projectFileCounts addObject:@(mainCount)];
    [_projectCompiledCounts addObject:@(0)];
    _currentProjectIndex = [_projectFileCounts count] - 1;

    if (_progressBar) {
        NSInteger totalEstimate = [self totalEstimatedFiles];
        [_progressBar setIndeterminate:NO];
        [_progressBar setMinValue:0];
        [_progressBar setMaxValue:totalEstimate > 0 ? totalEstimate : 1];
        [_progressBar setDoubleValue:0];
        if (totalEstimate <= 0) {
            // Could not estimate the number of source files; fall back to an
            // indeterminate bar for the whole build.
            [_progressBar setIndeterminate:YES];
            [_progressBar startAnimation:nil];
        }
    }

    NSString *dName = [self displayNameFromMakefile];
    if (_statusField) {
        [_statusField setStringValue:dName ? [NSString stringWithFormat:NSLocalizedString(@"Building %@…", @"Status: building a named app"), dName] : NSLocalizedString(@"Building…", @"Status: building (no name)")];
    }
    if (_window) [_window setTitle:dName ? [NSString stringWithFormat:NSLocalizedString(@"Building %@", @"Window title while building"), dName] : NSLocalizedString(@"Building…", @"Window title while building (no name)")];
    else fprintf(stderr, "Building…\n");
    [_logController appendLog:[NSString stringWithFormat:NSLocalizedString(@"=== Build started in %@ ===\n", @"Log: build started"), directory]];
    NSLog(@"build: directory=%@ makefilePath=%@", directory, makefilePath);

    buildTask = [[NSTask alloc] init];
    [buildTask setCurrentDirectoryPath:directory];
    [buildTask setLaunchPath:makePath];
    NSMutableArray *taskArgs = [NSMutableArray arrayWithObjects:@"-f", makefilePath, @"clean", nil];
    if (self.extraArgs) {
        [taskArgs addObjectsFromArray:self.extraArgs];
    }
    [taskArgs addObject:@"all"];
    [buildTask setArguments:taskArgs];

    // Add dependency include/lib paths to build command (reliable approach)
    NSString *depDir = [directory stringByAppendingPathComponent:@"GNUstepDependencies"];
    if (_dependencyResolved) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *subs = [fm contentsOfDirectoryAtPath:depDir error:NULL];
        if (subs) {
            NSMutableString *cppFlags = [NSMutableString string];
            NSMutableString *ldFlags = [NSMutableString string];
            NSMutableString *guiLibs = [NSMutableString string];
            for (NSString *sub in subs) {
                NSString *libDir = [depDir stringByAppendingPathComponent:sub];
                NSString *subName = [sub lastPathComponent];
                NSDictionary *subInfo = [[self gnustepInfo] objectForKey:subName];
                NSArray *hdrPrefixes = [subInfo objectForKey:@"headers"];
                NSString *libName = subName;
                if ([hdrPrefixes count] > 0) {
                    libName = [hdrPrefixes objectAtIndex:0];
                }
                // Header path
                NSArray *hdrCandidates = @[
                    [libDir stringByAppendingPathComponent:@"Headers"],
                    libDir
                ];
                for (NSString *hdrDir in hdrCandidates) {
                    if ([fm fileExistsAtPath:hdrDir]) {
                        NSArray *contents = [fm contentsOfDirectoryAtPath:hdrDir error:NULL];
                        for (NSString *f in contents) {
                            if ([[f pathExtension] isEqualToString:@"h"]) {
                                if ([cppFlags length] > 0) [cppFlags appendString:@" "];
                                [cppFlags appendFormat:@"-I%@", hdrDir];
                                break;
                            }
                        }
                        break;
                    }
                }
                // Library path and link flags
                NSString *objDir = [libDir stringByAppendingPathComponent:@"obj"];
                if ([fm fileExistsAtPath:objDir]) {
                    if ([ldFlags length] > 0) [ldFlags appendString:@" "];
                    [ldFlags appendFormat:@"-L%@", objDir];
                    if ([guiLibs length] > 0) [guiLibs appendString:@" "];
                    [guiLibs appendFormat:@"-l%@", libName];
                }
            }
            // Add rpath for runtime: libraries will be in Resources/
            NSString *appName = [self productNameFromMakefile];
            if (appName) {
                if ([ldFlags length] > 0) [ldFlags appendString:@" "];
                [ldFlags appendFormat:@"-Wl,-rpath,'$$ORIGIN/Resources'"];
            }
            // Insert before "all" target
            NSUInteger insertPos = [taskArgs count];
            for (NSUInteger i = 0; i < [taskArgs count]; i++) {
                if ([[taskArgs objectAtIndex:i] isEqualToString:@"all"]) {
                    insertPos = i;
                    break;
                }
            }
            if ([cppFlags length] > 0) {
                [taskArgs insertObject:[NSString stringWithFormat:@"CPPFLAGS=%@", cppFlags]
                               atIndex:insertPos++];
            }
            if ([ldFlags length] > 0) {
                [taskArgs insertObject:[NSString stringWithFormat:@"ADDITIONAL_LDFLAGS=%@", ldFlags]
                               atIndex:insertPos++];
            }
            if ([guiLibs length] > 0) {
                [taskArgs insertObject:[NSString stringWithFormat:@"ADDITIONAL_GUI_LIBS=%@", guiLibs]
                               atIndex:insertPos];
            }
        }
        [buildTask setArguments:taskArgs];
        [buildTask setEnvironment:[[NSProcessInfo processInfo] environment]];
    } else {
        [buildTask setEnvironment:[[NSProcessInfo processInfo] environment]];
    }

    outputPipe = [[NSPipe alloc] init];
    [buildTask setStandardOutput:outputPipe];
    [buildTask setStandardError:outputPipe];
    [buildTask setStandardInput:[NSFileHandle fileHandleWithNullDevice]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(taskDidTerminate:)
                                                 name:NSTaskDidTerminateNotification
                                               object:buildTask];

    NSFileHandle *outputHandle = [outputPipe fileHandleForReading];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(outputAvailable:)
                                                 name:NSFileHandleReadCompletionNotification
                                               object:outputHandle];
    [outputHandle readInBackgroundAndNotify];

    @try {
        [buildTask launch];
    } @catch (NSException *exception) {
        [_statusField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Error: Failed to start build: %@", @"Status: build failed to start"), [exception reason]]];
    }
}

- (void)showFileOpenDialog
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    [openPanel setTitle:NSLocalizedString(@"Select GNUmakefile", @"Open panel title")];
    [openPanel setCanChooseFiles:YES];
    [openPanel setCanChooseDirectories:YES];
    [openPanel setAllowsMultipleSelection:NO];

    NSString *defaultDir = @"/Developer/Library/Sources";
    if ([[NSFileManager defaultManager] fileExistsAtPath:defaultDir]) {
        [openPanel setDirectoryURL:[NSURL fileURLWithPath:defaultDir]];
    }

    NSInteger result = [openPanel runModal];
    if (result != NSModalResponseOK) {
        [self quitCleanly];
        return;
    }

    NSArray *urls = [openPanel URLs];
    if ([urls count] > 0) {
        NSString *path = [[urls objectAtIndex:0] path];
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
        if (isDir) {
            for (NSString *name in @[@"GNUmakefile", @"GNUmakefile.in"]) {
                NSString *mf = [path stringByAppendingPathComponent:name];
                if ([[NSFileManager defaultManager] fileExistsAtPath:mf]) {
                    self.makefilePath = mf;
                    [self createProgressWindow];
                    [self startBuild];
                    return;
                }
            }
        } else {
            self.makefilePath = path;
            [self createProgressWindow];
            [self startBuild];
        }
    }
}

- (void)outputAvailable:(NSNotification *)notification
{
    NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];
    if ([data length] > 0) {
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [self.buildOutput appendString:output];

        write(STDOUT_FILENO, [data bytes], [data length]);

        dispatch_async(dispatch_get_main_queue(), ^{
            [_logController appendLog:output];
        });

        if ([_projectFileCounts count] > 0) {
            // Count "Compiling file" lines for progress
            NSUInteger compiled = 0;
            NSUInteger pos = 0;
            while (pos < [output length]) {
                NSRange r = [output rangeOfString:@"Compiling file "
                                         options:0
                                           range:NSMakeRange(pos, [output length] - pos)];
                if (r.location == NSNotFound) break;
                compiled++;
                pos = r.location + r.length;
            }
            if (compiled > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self updateProgressForCompiledFiles:compiled
                                              taskRunning:[buildTask isRunning]];
                });
            }
        }

        [[notification object] readInBackgroundAndNotify];
    }
}

- (void)taskDidTerminate:(NSNotification *)notification
{
    NSTask *task = [notification object];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self buildFinished:task];
    });
}

- (void)buildFinished:(NSTask *)task
{
    int status = [task terminationStatus];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:task];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSFileHandleReadCompletionNotification
                                                  object:nil];

    [_progressBar stopAnimation:nil];
    [_progressBar setIndeterminate:NO];

    if (self.consoleMode) {
        exit(status == 0 ? 0 : status);
    }

    if (self.autoInstallLaunch) {
        if (status == 0) {
            NSString *ext = [self productExtensionFromMakefile];
            BOOL canLaunch = [ext isEqualToString:@"app"] || [ext isEqualToString:@"prefPane"];
            NSLog(@"autoInstallLaunch: status=0, canLaunch=%d", canLaunch);
            [self startInstallWithLaunch:canLaunch];
        } else {
            [_logController appendLog:[NSString stringWithFormat:
                @"\n=== Build failed (exit %d) ===\n\n", status]];
            [self quitCleanly];
        }
        return;
    }

    // After successful build, embed dependency libraries into the app bundle
    if (status == 0 && _dependencyResolved) {
        NSString *appName = [self productNameFromMakefile];
        if (appName) {
            NSString *dir = [makefilePath stringByDeletingLastPathComponent];
            NSString *appBundle = [[dir stringByAppendingPathComponent:appName]
                stringByAppendingPathExtension:@"app"];
            NSString *resDir = [appBundle stringByAppendingPathComponent:@"Resources"];
            NSString *depDir = [dir stringByAppendingPathComponent:@"GNUstepDependencies"];
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:depDir] && [fm fileExistsAtPath:resDir]) {
                NSArray *subs = [fm contentsOfDirectoryAtPath:depDir error:NULL];
                for (NSString *sub in subs) {
                    NSString *objDir = [[depDir stringByAppendingPathComponent:sub]
                        stringByAppendingPathComponent:@"obj"];
                    NSArray *objects = [fm contentsOfDirectoryAtPath:objDir error:NULL];
                    for (NSString *obj in objects) {
                        if ([[obj pathExtension] isEqualToString:@"so"] ||
                            [obj hasPrefix:@"lib"]) {
                            NSString *src = [objDir stringByAppendingPathComponent:obj];
                            NSString *dst = [resDir stringByAppendingPathComponent:obj];
                            [fm copyItemAtPath:src toPath:dst error:NULL];
                            NSLog(@"embed: copied %@ -> %@", [obj lastPathComponent], dst);
                        }
                    }
                }
            }
        }
    }

    NSString *dName = [self displayNameFromMakefile];

    if (status == 0) {
        [_progressBar setDoubleValue:[_progressBar maxValue]];
        [_statusField setStringValue:dName ? [NSString stringWithFormat:NSLocalizedString(@"%@ built successfully", @"Status: build succeeded for app"), dName] : NSLocalizedString(@"Build completed successfully", @"Status: build succeeded (no name)")];
        [_window setTitle:dName ? dName : NSLocalizedString(@"Build", @"Window title")];
    } else {
        [_statusField setStringValue:dName ? [NSString stringWithFormat:NSLocalizedString(@"Failed to build %@", @"Status: build failed for app"), dName] : NSLocalizedString(@"Build failed", @"Status: build failed (no name)")];
        [_window setTitle:dName ? dName : NSLocalizedString(@"Build", @"Window title")];
    }

    [_logController appendLog:[NSString stringWithFormat:
        NSLocalizedString(@"\n=== Build %@ (exit %d) ===\n\n", @"Log: build result"), status == 0 ? NSLocalizedString(@"succeeded", @"Build status") : NSLocalizedString(@"failed", @"Build status"), status]];

    if (_window) [_window orderOut:nil];

    // If the compiler could not find a header that the header database maps
    // to an installable package, offer to install it and rebuild. On decline
    // or install failure, fall through to the plain error dialog.
    if (status != 0 && [self offerPackageInstallForMissingHeaders]) {
        return;
    }

    if (status != 0) {
        [self setProjectLabel:GWBuildFileLabelRed];
    }

    NSString *succeededMsg = dName ? [NSString stringWithFormat:NSLocalizedString(@"%@ built successfully.", @"Dialog: build succeeded for app"), dName] : NSLocalizedString(@"The build completed successfully.", @"Dialog: build succeeded (no name)");
    NSString *failedTitle = dName ? [NSString stringWithFormat:NSLocalizedString(@"Failed to build %@", @"Dialog title: build failed for app"), dName] : NSLocalizedString(@"Build Failed", @"Dialog title: build failed (no name)");

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:(status == 0) ? NSLocalizedString(@"Build Succeeded", @"Alert title: build succeeded") : failedTitle];
    [alert setInformativeText:(status == 0)
        ? succeededMsg
        : [self formatErrorOutput:self.buildOutput]];
    if (status == 0) {
        NSImage *check = [NSImage imageNamed:@"check"];
        if (check) [alert setIcon:check];
    }

    BOOL canLaunch = NO;
    if (status == 0) {
        NSString *ext = [self productExtensionFromMakefile];
        canLaunch = [ext isEqualToString:@"app"] || [ext isEqualToString:@"prefPane"];
    }

    // Auto-resolve missing GNUstep libraries without dialog
    if (status != 0 && !_dependencyResolved) {
        NSLog(@"buildFinished: no dependencies to resolve, showing dialog");
    }

    if (status == 0) {
        if (canLaunch) {
            [alert addButtonWithTitle:NSLocalizedString(@"Install and Launch", @"Button: install and launch app")];
        }
        [alert addButtonWithTitle:NSLocalizedString(@"Install", @"Button: install app")];
    }
    [alert addButtonWithTitle: (status == 0) ? NSLocalizedString(@"OK", @"OK button") : NSLocalizedString(@"Cancel", @"Cancel button")];
    if (status != 0) {
        [alert addButtonWithTitle:NSLocalizedString(@"Show Build Log", @"Button: show build log")];
    }

    NSInteger button = [alert runModal];
    NSLog(@"buildFinished: button=%ld (status=%d, canLaunch=%d)", (long)button, status, canLaunch);

    if (status == 0 && canLaunch && button == NSAlertFirstButtonReturn) {
        NSLog(@"buildFinished: Install and Launch");
        [self startInstallWithLaunch:YES];
    } else if (status == 0 && button == (canLaunch ? NSAlertSecondButtonReturn : NSAlertFirstButtonReturn)) {
        NSLog(@"buildFinished: Install");
        [self startInstallWithLaunch:NO];
    } else if (status == 0) {
        NSLog(@"buildFinished: OK");
        [self setProjectLabel:GWBuildFileLabelYellow];
        [self cleanupTempDir];
        [self quitCleanly];
    } else if (status != 0 && button == NSAlertSecondButtonReturn) {
        NSLog(@"buildFinished: Show Build Log");
        [self showLog:nil];
    } else {
        NSLog(@"buildFinished: Cancel");
        [self cleanupTempDir];
        [self quitCleanly];
    }
    NSLog(@"buildFinished: done");
}

/* Quit the app after the result alert has fully unwound.  The Eau alert
 * panel stops its modal on the next run loop pass and the panel is still
 * being torn down while the button handler runs; terminating synchronously
 * then closes the panel mid-teardown and the window churn crashes the
 * desktop's window tracking (Workspace/Menu die flooded with BadWindow).
 * Terminating from a later, idle run loop pass (the same state a SIGTERM
 * finds) is clean.  Every finish path - OK/Cancel, install, launch, clone
 * failure - quits through here. */
- (void)quitCleanly
{
    [BuildController scheduleQuit];
}

+ (void)scheduleQuit
{
    [NSApp performSelector:@selector(terminate:)
                withObject:nil
                afterDelay:0.5
                   inModes:[NSArray arrayWithObjects:
                     NSDefaultRunLoopMode,
                     NSModalPanelRunLoopMode,
                     NSEventTrackingRunLoopMode,
                     nil]];
}

#pragma mark - Install

- (void)startInstallWithLaunch:(BOOL)shouldLaunch
{
    if (!makefilePath) return;

    installShouldLaunch = shouldLaunch;

    if (_window) {
        [_window orderFront:nil];
        [_window setTitle:NSLocalizedString(@"Installing…", @"Window title during install")];
    }
    [_statusField setStringValue:NSLocalizedString(@"Installing…", @"Status: installing")];
    [_progressBar setIndeterminate:YES];
    [_progressBar startAnimation:nil];
    [self.buildOutput setString:@""];
    [_logController appendLog:@"\n=== Install started ===\n"];

    NSString *directory = [makefilePath stringByDeletingLastPathComponent];
    if ([directory length] == 0) directory = @".";

    NSString *sudoPath = toolPath(@"sudo");
    if (!sudoPath) {
        [_statusField setStringValue:NSLocalizedString(@"Error: sudo not found in PATH", @"Status: sudo not found")];
        return;
    }
    NSString *gmakePath = toolPath(@"gmake");
    if (!gmakePath) {
        [_statusField setStringValue:NSLocalizedString(@"Error: gmake not found in PATH", @"Status: gmake not found")];
        return;
    }

    installTask = [[NSTask alloc] init];
    [installTask setCurrentDirectoryPath:directory];
    [installTask setLaunchPath:sudoPath];
    [installTask setArguments:@[@"-E", gmakePath, @"-f", makefilePath, @"install"]];
    [installTask setEnvironment:[[NSProcessInfo processInfo] environment]];

    installPipe = [[NSPipe alloc] init];
    [installTask setStandardOutput:installPipe];
    [installTask setStandardError:installPipe];
    [installTask setStandardInput:[NSFileHandle fileHandleWithNullDevice]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(installDidTerminate:)
                                                 name:NSTaskDidTerminateNotification
                                               object:installTask];

    NSFileHandle *handle = [installPipe fileHandleForReading];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(installOutputAvailable:)
                                                 name:NSFileHandleReadCompletionNotification
                                               object:handle];
    [handle readInBackgroundAndNotify];

    @try {
        [installTask launch];
    } @catch (NSException *exception) {
        [_statusField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Install failed: %@", @"Status: install failed with reason"), [exception reason]]];
        installTask = nil;
        installPipe = nil;
    }
}

- (void)installOutputAvailable:(NSNotification *)notification
{
    NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];
    if ([data length] > 0) {
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [self.buildOutput appendString:output];

        write(STDOUT_FILENO, [data bytes], [data length]);

        dispatch_async(dispatch_get_main_queue(), ^{
            [_logController appendLog:output];
        });

        [[notification object] readInBackgroundAndNotify];
    }
}

- (void)installDidTerminate:(NSNotification *)notification
{
    NSTask *task = [notification object];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installFinished:task];
    });
}

- (void)installFinished:(NSTask *)task
{
    int status = [task terminationStatus];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:task];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSFileHandleReadCompletionNotification
                                                  object:nil];
    installTask = nil;
    installPipe = nil;

    [_progressBar stopAnimation:nil];
    [_progressBar setIndeterminate:NO];
    [_window setTitle:NSLocalizedString(@"Build", @"Window title")];

    [_logController appendLog:[NSString stringWithFormat:
        NSLocalizedString(@"\n=== Install %@ (exit %d) ===\n", @"Log: install result"), status == 0 ? NSLocalizedString(@"succeeded", @"Build status") : NSLocalizedString(@"failed", @"Build status"), status]];

    if (_window) [_window orderOut:nil];

    if (status != 0) {
        [_statusField setStringValue:NSLocalizedString(@"Install failed", @"Status: install failed")];
        [self setProjectLabel:GWBuildFileLabelRed];

        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Install Failed", @"Alert title: install failed")];
        [alert setInformativeText:[self formatErrorOutput:self.buildOutput]];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel button")];
        [alert addButtonWithTitle:NSLocalizedString(@"Show Build Log", @"Button: show build log")];
        NSInteger button = [alert runModal];

        if (button == NSAlertSecondButtonReturn) {
            [self showLog:nil];
            return;
        }
        [self cleanupTempDir];
        [self quitCleanly];
        return;
    }

    [_statusField setStringValue:NSLocalizedString(@"Install completed", @"Status: install finished")];

    if (installShouldLaunch) {
        NSString *name = [self productNameFromMakefile];
        NSString *ext = [self productExtensionFromMakefile];
        if (name) {
            NSString *productPath = nil;
            if ([ext isEqualToString:@"prefPane"]) {
                NSString *bundlesDir = [NSSearchPathForDirectoriesInDomains(
                    NSLibraryDirectory, NSSystemDomainMask, YES) lastObject];
                bundlesDir = [bundlesDir stringByAppendingPathComponent:@"Bundles"];
                productPath = [[bundlesDir stringByAppendingPathComponent:name]
                    stringByAppendingPathExtension:ext];
                if (![[NSFileManager defaultManager] fileExistsAtPath:productPath]) {
                    productPath = nil;
                }
            } else {
                [[NSWorkspace sharedWorkspace] findApplications];
                productPath = [[NSWorkspace sharedWorkspace] fullPathForApplication:name];
            }
            if (productPath) {
                /* launchApplication: connects to the target app via DO and can
                   block while the freshly installed app is starting.  Run the
                   launch off the main thread so the UI does not freeze; the
                   terminate/cleanup that follows stays ordered after it.  The
                   launch result decides the project's green/red label. */
                [NSThread detachNewThreadWithBlock: ^{
                    BOOL launched = NO;
                    if ([ext isEqualToString:@"prefPane"]) {
                        launched = [[NSWorkspace sharedWorkspace] launchApplication:@"SystemPreferences"];
                    } else {
                        launched = [[NSWorkspace sharedWorkspace] launchApplication:name];
                    }
                    [self performSelectorOnMainThread: @selector(finishLaunchAndExit:)
                                           withObject: [NSNumber numberWithBool:launched]
                                        waitUntilDone: NO];
                }];
                return;
            }
        }

        [self setProjectLabel:GWBuildFileLabelRed];
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Launch Failed", @"Alert title: launch failed")];
        [alert setInformativeText:NSLocalizedString(@"The application was installed, but could not be launched.", @"Alert: installed but failed to launch")];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
        [alert runModal];
    } else {
        [self setProjectLabel:GWBuildFileLabelYellow];
    }

    [self cleanupTempDir];
    [self quitCleanly];
}

- (NSString *)displayNameFromMakefile
{
    NSString *content = [NSString stringWithContentsOfFile:makefilePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!content) return nil;

    // Prefer the actual product name (descends into subprojects for aggregate
    // makefiles, e.g. the AddressManager app inside an "Addresses" aggregate)
    // over the aggregate's PACKAGE_NAME.
    NSString *product = [self productNameFromMakefile:makefilePath];
    if ([product length] > 0) return product;

    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    for (NSString *varName in @[@"APP_NAME", @"PACKAGE_NAME"]) {
        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            if ([trimmed hasPrefix:varName]) {
                NSString *val = [self parseVariableValue:trimmed];
                if ([val length] > 0) return val;
            }
        }
    }
    return nil;
}

- (NSImage *)productIconFromMakefile
{
    NSString *content = [NSString stringWithContentsOfFile:makefilePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!content) return nil;

    NSString *target = [self productNameFromMakefile];
    NSString *dir = [makefilePath stringByDeletingLastPathComponent];

    // Join backslash continuations
    NSMutableString *joined = [NSMutableString stringWithString:content];
    [joined replaceOccurrencesOfString:@"\\\n"
                            withString:@" "
                               options:0
                                 range:NSMakeRange(0, [joined length])];
    NSArray *joinedLines = [joined componentsSeparatedByString:@"\n"];

    // Step 1: try APPLICATION_ICON from makefile
    NSString *imgName = nil;
    for (NSString *line in joinedLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        NSArray *vars = @[[NSString stringWithFormat:@"%@_APPLICATION_ICON", target],
                          @"APPLICATION_ICON"];
        for (NSString *var in vars) {
            if ([trimmed hasPrefix:var]) {
                imgName = [self parseVariableValue:trimmed];
                if ([imgName length] > 0) break;
            }
        }
        if (imgName) break;
    }

    if (imgName) {
        NSArray *exts = @[@"png", @"tiff", @"jpg", @"jpeg", @"icns", @"tif",
                          [imgName pathExtension]];
        NSArray *locations = @[dir, [dir stringByAppendingPathComponent:@"Resources"]];
        NSString *stem = [imgName stringByDeletingPathExtension];

        for (NSString *location in locations) {
            for (NSString *ext in exts) {
                NSString *path = [[location stringByAppendingPathComponent:stem]
                    stringByAppendingPathExtension:ext];
                if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    NSLog(@"icon: found at %@", path);
                    return [[NSImage alloc] initWithContentsOfFile:path];
                }
                NSLog(@"icon: not at %@", path);
            }
            NSString *exactPath = [location stringByAppendingPathComponent:imgName];
            if ([[NSFileManager defaultManager] fileExistsAtPath:exactPath]) {
                NSLog(@"icon: found at %@", exactPath);
                return [[NSImage alloc] initWithContentsOfFile:exactPath];
            }
            NSLog(@"icon: not at %@", exactPath);
        }

        // Try RESOURCE_FILES entries matching imgName
        for (NSString *line in joinedLines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            if (![trimmed hasPrefix:@"RESOURCE_FILES"] &&
                (target && ![trimmed hasPrefix:[NSString stringWithFormat:@"%@_RESOURCE_FILES", target]])) continue;
            NSString *val = [self parseVariableValue:trimmed];
            if ([val length] == 0) continue;
            NSArray *parts = [val componentsSeparatedByCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            for (NSString *part in parts) {
                if ([part length] == 0 || [part isEqualToString:@"\\"]) continue;
                if ([[part lastPathComponent] isEqualToString:imgName]) {
                    NSString *fullPath = [dir stringByAppendingPathComponent:part];
                    fullPath = [fullPath stringByStandardizingPath];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
                        NSLog(@"icon: found via RESOURCE_FILES at %@", fullPath);
                        return [[NSImage alloc] initWithContentsOfFile:fullPath];
                    }
                    NSLog(@"icon: RESOURCE_FILES entry %@ not found at %@", part, fullPath);
                }
            }
        }
    }

    // Step 2: scan RESOURCE_FILES for icon-like filenames
    for (NSString *line in joinedLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (![trimmed hasPrefix:@"RESOURCE_FILES"] &&
            (target && ![trimmed hasPrefix:[NSString stringWithFormat:@"%@_RESOURCE_FILES", target]])) continue;
        NSString *val = [self parseVariableValue:trimmed];
        if ([val length] == 0) continue;
        NSArray *parts = [val componentsSeparatedByCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        for (NSString *part in parts) {
            if ([part length] == 0 || [part isEqualToString:@"\\"]) continue;
            NSString *fn = [part lastPathComponent];
            NSString *fnLower = [fn lowercaseString];
            if ([fnLower hasPrefix:@"appicon"] || [fnLower hasPrefix:@"icon"] ||
                [fnLower hasPrefix:@"icon_"]) {
                NSString *fullPath = [dir stringByAppendingPathComponent:part];
                fullPath = [fullPath stringByStandardizingPath];
                if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
                    NSLog(@"icon: found icon-like resource at %@", fullPath);
                    return [[NSImage alloc] initWithContentsOfFile:fullPath];
                }
            }
        }
    }

    // Step 3: look for pre-built .app bundles in source tree
    NSArray *subDirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    for (NSString *sub in subDirs) {
        if ([[sub pathExtension] isEqualToString:@"app"]) {
            NSString *appBundle = [dir stringByAppendingPathComponent:sub];
            NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:appBundle];
            if (icon) {
                NSLog(@"icon: from pre-built .app %@", appBundle);
                return icon;
            }
        }
    }

    // Step 4: look for .app bundles in SUBPROJECTS directories
    for (NSString *line in joinedLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"SUBPROJECTS"]) {
            NSString *val = [self parseVariableValue:trimmed];
            if ([val length] == 0) continue;
            NSArray *subs = [val componentsSeparatedByCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            for (NSString *sub in subs) {
                if ([sub length] == 0 || [sub isEqualToString:@"\\"]) continue;
                NSString *subDir = [dir stringByAppendingPathComponent:sub];
                NSArray *subContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:subDir error:NULL];
                for (NSString *item in subContents) {
                    if ([[item pathExtension] isEqualToString:@"app"]) {
                        NSString *appBundle = [subDir stringByAppendingPathComponent:item];
                        NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:appBundle];
                        if (icon) {
                            NSLog(@"icon: from SUBPROJECTS .app %@", appBundle);
                            return icon;
                        }
                    }
                }
            }
        }
    }

    // Step 5: try pre-built .app bundle matching target name
    if (target) {
        NSString *appBundle = [[dir stringByAppendingPathComponent:target]
            stringByAppendingPathExtension:@"app"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:appBundle]) {
            NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:appBundle];
            if (icon) {
                NSLog(@"icon: from pre-built .app %@", appBundle);
                return icon;
            }
        }
    }

    NSLog(@"icon: not found");
    return nil;
}

#pragma mark - Helpers

- (NSString *)productNameFromMakefile
{
    return [self productNameFromMakefile:makefilePath];
}

- (NSString *)productNameFromMakefile:(NSString *)path
{
    return [self productNameFromMakefile:path depth:0];
}

- (NSString *)productNameFromMakefile:(NSString *)path depth:(NSInteger)depth
{
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!content) return nil;

    // Join backslash continuations so multi-line SUBPROJECTS / file lists
    // appear on a single logical line.
    NSMutableString *joined = [NSMutableString stringWithString:content];
    [joined replaceOccurrencesOfString:@"\\\n"
                            withString:@" "
                               options:0
                                 range:NSMakeRange(0, [joined length])];
    NSArray *lines = [joined componentsSeparatedByString:@"\n"];

    NSMutableArray *subprojects = [NSMutableArray array];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"APP_NAME"] || [trimmed hasPrefix:@"BUNDLE_NAME"] ||
            [trimmed hasPrefix:@"TOOL_NAME"]) {
            NSString *name = [self parseVariableValue:trimmed];
            if ([name length] > 0) return name;
        } else if ([trimmed hasPrefix:@"SUBPROJECTS"] && depth < 3) {
            NSString *vals = [self parseVariableValue:trimmed];
            if ([vals length] > 0) {
                [subprojects addObjectsFromArray:[vals componentsSeparatedByString:@" "]];
            }
        }
    }

    // Aggregate makefiles (SUBPROJECTS, no direct product): descend into each
    // subproject's GNUmakefile until an app/tool/bundle name is found.
    if (depth < 3) {
        NSString *dir = [path stringByDeletingLastPathComponent];
        for (NSString *sub in subprojects) {
            if ([sub length] == 0) continue;
            NSString *subMakefile = [[dir stringByAppendingPathComponent:sub]
                stringByAppendingPathComponent:@"GNUmakefile"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:subMakefile]) continue;
            NSString *name = [self productNameFromMakefile:subMakefile depth:depth + 1];
            if (name) return name;
        }
    }

    return nil;
}

- (NSInteger)countSourceFilesInMakefile:(NSString *)path
                                  target:(NSString *)target
                                   depth:(NSInteger)depth
{
    if (depth > 3) return 0;
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!content) return 0;

    // Join backslash continuation lines
    NSMutableString *joined = [NSMutableString stringWithString:content];
    [joined replaceOccurrencesOfString:@"\\\n"
                            withString:@" "
                               options:0
                                 range:NSMakeRange(0, [joined length])];

    NSInteger count = 0;
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSArray *varNames = @[
        @"OBJC_FILES", @"OBJCXX_FILES", @"C_FILES", @"CC_FILES",
        @"CPP_FILES", @"CXX_FILES", @"OBJCPP_FILES"
    ];
    NSArray *lines = [joined componentsSeparatedByString:@"\n"];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];

        // Variable name on the left-hand side of an assignment, if any.
        NSString *varName = nil;
        NSRange eqRange = [trimmed rangeOfString:@"="];
        if (eqRange.location != NSNotFound) {
            varName = [trimmed substringToIndex:eqRange.location];
            varName = [varName stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            // Strip assignment modifiers such as ':' (:=) and '+' (+=).
            NSCharacterSet *modifiers = [NSCharacterSet characterSetWithCharactersInString:@":+"];
            while ([varName length] > 0 &&
                   [modifiers characterIsMember:
                       [varName characterAtIndex:[varName length] - 1]]) {
                varName = [varName substringToIndex:[varName length] - 1];
            }
            varName = [varName stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
        }

        if ([varName length] > 0) {
            // Count source file variables.  Match the bare name (OBJC_FILES),
            // the target-prefixed form (TheUnarchiver_OBJC_FILES), or any
            // _OBJC_FILES-style variable: gnustep-make compiles all of them
            // (LIBRARY_OBJC_FILES and the tool lists from Makefile.common,
            // per-target SUBPROJECTS, etc.), so counting only the bare or
            // target-prefixed form under-counts badly for library projects.
            for (NSString *var in varNames) {
                NSString *prefixed = target ? [NSString stringWithFormat:@"%@_%@", target, var] : nil;
                if ([varName isEqualToString:var]
                    || (prefixed && [varName isEqualToString:prefixed])
                    || [varName hasSuffix:[@"_" stringByAppendingString:var]]) {
                    NSString *value = [self parseVariableValue:trimmed];
                    if ([value length] > 0) {
                        NSArray *parts = [value componentsSeparatedByCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
                        for (NSString *part in parts) {
                            if ([part length] > 0 && ![part isEqualToString:@"\\"]) {
                                count++;
                            }
                        }
                    }
                    break;
                }
            }
        }

        // Recurse into local includes (skip system includes with $()
        if ([trimmed hasPrefix:@"include "]) {
            NSString *incPath = [[trimmed substringFromIndex:8]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([incPath hasPrefix:@"$("]) continue;
            if (![incPath isAbsolutePath]) {
                incPath = [dir stringByAppendingPathComponent:incPath];
            }
            incPath = [incPath stringByStandardizingPath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:incPath]) {
                count += [self countSourceFilesInMakefile:incPath
                                                   target:target
                                                    depth:depth + 1];
            }
        }

        // Recurse into SUBPROJECTS, including the per-target xxx_SUBPROJECTS
        // form (e.g. TheUnarchiver_SUBPROJECTS) used by many apps.
        if ([varName isEqualToString:@"SUBPROJECTS"]
            || (varName && [varName hasSuffix:@"_SUBPROJECTS"])) {
            NSString *val = [self parseVariableValue:trimmed];
            if ([val length] > 0) {
                NSArray *subs = [val componentsSeparatedByCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                for (NSString *sub in subs) {
                    if ([sub length] == 0 || [sub isEqualToString:@"\\"]) continue;
                    NSString *subMf = [[dir stringByAppendingPathComponent:sub]
                        stringByAppendingPathComponent:@"GNUmakefile"];
                    subMf = [subMf stringByStandardizingPath];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:subMf]) {
                        NSString *subTarget = [self productNameFromMakefile:subMf];
                        count += [self countSourceFilesInMakefile:subMf
                                                           target:subTarget
                                                            depth:depth + 1];
                    }
                }
            }
        }
    }

    return count;
}

- (NSInteger)totalEstimatedFiles
{
    NSInteger total = 0;
    for (NSNumber *n in _projectFileCounts) {
        total += [n integerValue];
    }
    return total;
}

/* Advance the progress bar by the given number of just-compiled files.
   The bar runs from 0 to totalEstimatedFiles (the sum of all project
   segments).  If the static estimate is exhausted while a build task is
   still running - which happens whenever the estimate under-counts, e.g.
   for makefiles that use $(VAR) indirection - a determinate bar would sit
   at 100% until the build ends.  In that case fall back to an indeterminate
   bar; buildFinished sets it to 100% when the build actually completes. */
- (void)updateProgressForCompiledFiles:(NSInteger)compiled taskRunning:(BOOL)running
{
    if (!_progressBar) return;
    if ([_projectFileCounts count] == 0 || compiled <= 0) return;

    NSInteger curTotal = [_projectFileCounts[_currentProjectIndex] integerValue];
    NSInteger curCompiled = [_projectCompiledCounts[_currentProjectIndex] integerValue] + compiled;
    if (curCompiled > curTotal) curCompiled = curTotal;
    _projectCompiledCounts[_currentProjectIndex] = @(curCompiled);

    NSInteger totalCompiled = 0;
    for (NSNumber *n in _projectCompiledCounts) {
        totalCompiled += [n integerValue];
    }
    NSInteger totalEstimate = [self totalEstimatedFiles];

    if (totalEstimate <= 0 || (running && totalCompiled >= totalEstimate)) {
        if (![_progressBar isIndeterminate]) {
            [_progressBar setIndeterminate:YES];
            [_progressBar startAnimation:nil];
        }
    } else {
        [_progressBar setMaxValue:totalEstimate];
        [_progressBar setDoubleValue:totalCompiled];
    }
}

- (NSString *)productExtensionFromMakefile
{
    NSString *content = [NSString stringWithContentsOfFile:makefilePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!content) return nil;

    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    BOOL hasBundleName = NO;
    NSString *ext = nil;

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"BUNDLE_NAME"]) {
            hasBundleName = YES;
        } else if ([trimmed hasPrefix:@"BUNDLE_EXTENSION"]) {
            ext = [self parseVariableValue:trimmed];
        } else if ([trimmed hasPrefix:@"APP_NAME"]) {
            return @"app";
        } else if ([trimmed hasPrefix:@"TOOL_NAME"]) {
            return @"tool";
        }
    }

    if (hasBundleName) {
        if ([ext length] > 0) {
            // Strip leading dot if present
            if ([ext hasPrefix:@"."]) {
                ext = [ext substringFromIndex:1];
            }
            return ext;
        }
        return @"bundle";
    }

    return @"app";
}

- (NSArray *)scanMissingHeadersList:(NSArray *)lines
{
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *line in lines) {
        NSScanner *scanner = [NSScanner scannerWithString:line];
        NSString *header;
        if ([scanner scanUpToString:@"fatal error: '" intoString:NULL]) {
            if ([scanner scanString:@"fatal error: '" intoString:NULL]) {
                if ([scanner scanUpToString:@"' file not found" intoString:&header]) {
                    if ([header length] > 0 && ![missing containsObject:header]) {
                        [missing addObject:header];
                    }
                }
            }
        }
    }
    return missing;
}

- (NSString *)scanMissingHeaders:(NSArray *)lines
{
    NSArray *missing = [self scanMissingHeadersList:lines];
    if ([missing count] > 0) {
        return [self formatMissingItems:@"header" items:missing];
    }
    return nil;
}

- (NSString *)scanMissingLibraries:(NSArray *)lines
{
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *line in lines) {
        // GNU ld: /bin/ld: cannot find -lmpv: No such file or directory
        // Apple ld: ld: library not found for -lmpv
        NSScanner *scanner = [NSScanner scannerWithString:line];
        NSString *lib;
        [scanner scanUpToString:@"cannot find -l" intoString:NULL];
        if ([scanner scanString:@"cannot find -l" intoString:NULL]) {
            NSCharacterSet *stop = [NSCharacterSet characterSetWithCharactersInString:@": \t"];
            if ([scanner scanUpToCharactersFromSet:stop intoString:&lib]) {
                if ([lib length] > 0) {
                    [missing addObject:lib];
                }
            }
        } else {
            scanner = [NSScanner scannerWithString:line];
            [scanner scanUpToString:@"library not found for -l" intoString:NULL];
            if ([scanner scanString:@"library not found for -l" intoString:NULL]) {
                NSCharacterSet *stop = [NSCharacterSet characterSetWithCharactersInString:@": \t"];
                if ([scanner scanUpToCharactersFromSet:stop intoString:&lib]) {
                    if ([lib length] > 0) {
                        [missing addObject:lib];
                    }
                }
            }
        }
    }
    if ([missing count] > 0) {
        return [self formatMissingItems:@"library" items:missing];
    }
    return nil;
}

- (NSArray *)blacklist
{
    if (!_blacklist) {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"Blacklist" ofType:@"plist"];
        NSArray *loaded = path ? [NSArray arrayWithContentsOfFile:path] : nil;
        _blacklist = loaded ?: @[];
    }
    return _blacklist;
}

- (BOOL)isItemBlacklisted:(NSString *)item
{
    NSString *stem = [[item lowercaseString] stringByDeletingPathExtension];
    for (NSString *blacklisted in self.blacklist) {
        NSString *b = [blacklisted lowercaseString];
        if ([stem isEqualToString:b]) return YES;
        if ([stem hasPrefix:b]) return YES;
    }
    return NO;
}

- (NSString *)formatMissingItems:(NSString *)kind items:(NSArray *)items
{
    NSMutableArray *allowed = [NSMutableArray array];
    NSMutableArray *blocked = [NSMutableArray array];
    for (NSString *item in items) {
        if ([self isItemBlacklisted:item]) {
            [blocked addObject:item];
        } else {
            [allowed addObject:item];
        }
    }

    NSMutableString *friendly = [NSMutableString string];

    if ([blocked count] > 0) {
        [friendly appendString:NSLocalizedString(@"The build failed because it requires an unsupported technology:\n\n", @"Error: unsupported technology")];
        for (NSString *item in blocked) {
            [friendly appendFormat:@"  • %@\n", item];
        }
    }

    if ([allowed count] > 0) {
        if ([blocked count] > 0) {
            [friendly appendString:NSLocalizedString(@"\nAdditionally, a required package is missing:\n\n", @"Error: also missing package")];
        } else {
            [friendly appendFormat:NSLocalizedString(@"The build failed because a required %@ is missing:\n\n", @"Error: missing item of kind"), kind];
        }
        for (NSString *item in allowed) {
            [friendly appendFormat:@"  • %@\n", item];
        }
    }

    if ([allowed count] > 0) {
        [friendly appendString:NSLocalizedString(@"\nAfter installing the corresponding development package, try building again.", @"Hint: install dev package")];
    } else if ([blocked count] > 0) {
        [friendly appendString:NSLocalizedString(@"\nPlease consider an alternative, as this technology is not planned to be supported on this system.", @"Hint: use alternative")];
    }
    return friendly;
}

- (NSString *)formatErrorOutput:(NSString *)output
{
    NSArray *lines = [output componentsSeparatedByString:@"\n"];

    NSString *headerMsg = [self scanMissingHeaders:lines];
    if (headerMsg) return headerMsg;

    NSString *libMsg = [self scanMissingLibraries:lines];
    if (libMsg) return libMsg;

    NSMutableArray *cleanLines = [NSMutableArray array];
    for (NSString *line in lines) {
        if ([line length] > 0) {
            [cleanLines addObject:line];
        }
    }

    NSUInteger totalLines = [cleanLines count];
    if (totalLines == 0) {
        return NSLocalizedString(@"No output captured", @"Error: no build output");
    }

    NSMutableString *formattedOutput = [NSMutableString string];

    NSUInteger firstCount = MIN(5, totalLines);
    for (NSUInteger i = 0; i < firstCount; i++) {
        [formattedOutput appendFormat:@"%@\n", [cleanLines objectAtIndex:i]];
    }

    if (totalLines > 5) {
        [formattedOutput appendString:@"...\n"];

        NSUInteger lastCount = MIN(25, totalLines - 5);
        NSUInteger startIndex = totalLines - lastCount;
        for (NSUInteger i = startIndex; i < totalLines; i++) {
            [formattedOutput appendFormat:@"%@\n", [cleanLines objectAtIndex:i]];
        }
    }

    return formattedOutput;
}

- (BOOL)offerPackageInstallForMissingHeaders
{
    // Console builds run through main.m and never reach this dialog; the
    // preflight already prompts there before building.
    if (!_window || _headerInstallOffered) return NO;

    NSArray *lines = [self.buildOutput componentsSeparatedByString:@"\n"];
    NSArray *missing = [self scanMissingHeadersList:lines];
    if ([missing count] == 0) return NO;

    GWHeaderDatabase *db = [GWHeaderDatabase sharedDatabase];
    if (!db || ![db isOpen]) return NO;
    NSString *distro = [db databaseDistroForCurrentOS];
    if (!distro) return NO;

    NSMutableArray *packages = [NSMutableArray array];
    for (NSString *header in missing) {
        // If the header already exists on the system, the compiler's failure
        // is a project-side build-system problem (e.g. a dead -config tool),
        // so reinstalling a package would not help. Only offer packages that
        // provide a header genuinely absent from disk.
        if ([db isHeaderInstalled:header distro:distro]) continue;
        NSError *error = nil;
        NSString *pkg = [db packageForHeader:header distro:distro error:&error];
        if (pkg && ![packages containsObject:pkg]) {
            [packages addObject:pkg];
        }
    }
    if ([packages count] == 0) return NO;

    _headerInstallOffered = YES;

    NSString *list = [packages componentsJoinedByString:@"\n"];
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"Install missing packages and rebuild?", @"Alert title: install missing packages and rebuild")];
    [alert setInformativeText:[NSString stringWithFormat:
        NSLocalizedString(@"The build needs headers from these packages:\n\n%@\n\nInstall them now and try building again?", @"Alert message: install packages to fix build"), list]];
    [alert addButtonWithTitle:NSLocalizedString(@"Install and Rebuild", @"Button: install packages and rebuild")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel button")];
    NSImage *icon = [self productIconFromMakefile] ?: [NSApp applicationIconImage];
    if (icon) [alert setIcon:icon];

    if ([alert runModal] != NSAlertFirstButtonReturn) return NO;

    NSError *error = nil;
    BOOL ok = [[GWPackageManager sharedManager] installPackages:packages
                                                 localFilePaths:@[]
                                                       progress:nil
                                                          error:&error];
    if (!ok) {
        NSLog(@"offerPackageInstallForMissingHeaders: install failed: %@", [error localizedDescription]);
        return NO;
    }

    [self startBuild];
    return YES;
}

- (NSString *)parseVariableValue:(NSString *)line
{
    NSScanner *scanner = [NSScanner scannerWithString:line];
    [scanner scanUpToString:@"=" intoString:NULL];
    [scanner scanString:@"=" intoString:NULL];
    NSString *value = nil;
    [scanner scanUpToString:@"\n" intoString:&value];
    return [value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
}

- (void)cleanupTempDir
{
    if (_objDir) {
        [[NSFileManager defaultManager] removeItemAtPath:_objDir error:NULL];
        _objDir = nil;
    }
}

- (void)cleanupCatalogBuildDir
{
    if (self.buildDir) {
        [[NSFileManager defaultManager] removeItemAtPath:self.buildDir error:NULL];
        self.buildDir = nil;
    }
}

/* Runs on the main thread after the launched app has started (see the
   install-and-launch path): finish cleanup and exit.  Split out so the
   potentially blocking NSWorkspace launch can run on a background thread. */
- (void)finishLaunchAndExit:(id)launchResult
{
    /* launchResult wraps launchApplication:'s BOOL; nil means no launch was
       attempted.  The launch outcome is what decides the green/red label. */
    BOOL launched = launchResult ? [launchResult boolValue] : NO;
    [self setProjectLabel:(launched ? GWBuildFileLabelGreen : GWBuildFileLabelRed)];
    if (!self.keepBuildDir) {
        [self cleanupCatalogBuildDir];
    }
    [self cleanupTempDir];
    [self quitCleanly];
}

/* The label helpers live in libGSMetadata / libDSStore, which are part of the
 * Workspace stack and only present on a full desktop install.  Load them with
 * dlopen() so Build.app still runs on systems without them; the label simply
 * is not applied then. */
- (Class)gsMetadataClass
{
    static Class cls = Nil;
    if (!cls) {
        void *handle = dlopen("/System/Library/Libraries/libGSMetadata.so", RTLD_NOW);
        if (handle) {
            cls = NSClassFromString(@"GSFileMetadata");
        } else {
            NSLog(@"gsMetadataClass: dlopen failed: %s", dlerror());
        }
    }
    return cls;
}

- (Class)dsStoreClass
{
    static Class cls = Nil;
    if (!cls) {
        void *handle = dlopen("/System/Library/Libraries/libDSStore.so", RTLD_NOW);
        if (handle) {
            cls = NSClassFromString(@"DSStore");
        } else {
            NSLog(@"dsStoreClass: dlopen failed: %s", dlerror());
        }
    }
    return cls;
}

/* Tag the directory containing the built GNUmakefile with a label color
 * (green = built and launched, yellow = built but not launched, red = any
 * failure).  Two layers, mirroring what Workspace.m -setLabelForNodes: does:
 *   1. the xattr label on the directory itself (canonical, travels with it),
 *   2. an lclr entry in the parent's .DS_Store so the parent's icon views
 *      show the dot immediately. */
- (void)setProjectLabel:(GWBuildFileLabel)label
{
    NSString *dirPath = [makefilePath stringByDeletingLastPathComponent];
    if ([dirPath length] == 0) return;

    Class metadataClass = [self gsMetadataClass];
    Class dsStoreClass = [self dsStoreClass];
    if (!metadataClass || !dsStoreClass) {
        NSLog(@"setProjectLabel: label libraries unavailable");
        return;
    }

    GSFileMetadata *md = [metadataClass metadataForFileAtPath:dirPath];
    if (!md) {
        md = [[[metadataClass alloc] init] autorelease];
    }
    [md setLabelNumber:(NSInteger)label];
    [md writeToFileAtPath:dirPath error:NULL];

    NSString *parent = [dirPath stringByDeletingLastPathComponent];
    NSString *storePath = [parent stringByAppendingPathComponent:@".DS_Store"];
    @try {
        DSStore *store = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:storePath]) {
            store = [dsStoreClass storeWithPath:storePath];
            if (![store load]) store = nil;
        }
        if (!store) {
            store = [dsStoreClass createStoreAtPath:storePath withEntries:nil];
        }
        [store setLabelColorForFilename:[dirPath lastPathComponent]
                                  color:(NSInteger)label];
        [store save];
    } @catch (NSException *exception) {
        NSLog(@"setProjectLabel: .DS_Store update failed: %@", exception);
    }
}

- (NSDictionary *)gnustepInfo
{
    if (!_gnustepInfo) {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"GNUstep.info" ofType:@"plist"];
        if (path) {
            _gnustepInfo = [NSDictionary dictionaryWithContentsOfFile:path];
        }
        if (!_gnustepInfo) {
            _gnustepInfo = @{};
        }
    }
    return _gnustepInfo;
}

- (NSString *)repoForMissingHeader:(NSString *)header
{
    // Extract the first path component (e.g., "WebServices" from "WebServices/GWSService.h")
    // or first two for paths like "gnustep/gui/XXX.h"
    NSString *first = header;
    NSString *firstTwo = nil;
    NSRange slash = [header rangeOfString:@"/"];
    if (slash.location != NSNotFound) {
        first = [header substringToIndex:slash.location];
        NSRange secondSlash = [header rangeOfString:@"/"
                                            options:0
                                              range:NSMakeRange(slash.location + 1, [header length] - slash.location - 1)];
        if (secondSlash.location != NSNotFound) {
            firstTwo = [header substringToIndex:secondSlash.location];
        }
    }

    // Look for a repo whose headers array contains first or firstTwo
    for (NSString *repo in [self gnustepInfo]) {
        NSDictionary *info = [[self gnustepInfo] objectForKey:repo];
        NSArray *headers = [info objectForKey:@"headers"];
        if ([headers containsObject:first] || (firstTwo && [headers containsObject:firstTwo])) {
            // Check if the header directory exists (library already installed)
            NSString *headerDir = [@"/System/Library/Headers" stringByAppendingPathComponent:first];
            if (![[NSFileManager defaultManager] fileExistsAtPath:headerDir]) {
                return repo;
            }
        }
    }
    return nil;
}

// Appends a line to the build transcript shown in the log window.
- (void)appendBuildOutputLine:(NSString *)line
{
    NSString *text = [line stringByAppendingString:@"\n"];
    [self.buildOutput appendString:text];
    [_logController appendLog:text];
}

// Scans the project sources for system headers and installs the packages
// that provide the missing ones, with the user's consent.  Returns NO when
// the build must not continue (user cancelled, or an install failed).
- (BOOL)runPackagePreflightInDirectory:(NSString *)directory
{
    self.preflightInstalledPackages = NO;

    // Determine the scan root: for multi-library repos we cover the whole
    // checkout, otherwise just the makefile's directory.
    NSString *scanRoot = [self findRepoRootFromMakefileDir:directory
                                                   buildDir:self.buildDir];
    if (!scanRoot) scanRoot = directory;

    GWBuildPreflight *preflight = [[GWBuildPreflight alloc]
        initWithSourceRoot:scanRoot makefilePath:makefilePath];
    [preflight setConsoleMode:(self.consoleMode || getenv("DISPLAY") == NULL)];
    [preflight setBlacklist:self.blacklist];
    // Same icon the progress window shows for this project, so the consent
    // dialog and the progress window display the product being built.
    [preflight setIconImage:[self productIconFromMakefile]];

    __block NSError *preflightError = nil;

    GWPreflightDecision decision = [preflight runWithProgress:^(float progress, NSString *message) {
        if (progress < 1.0) {
            [self appendBuildOutputLine:[NSString stringWithFormat:
                @"[preflight %3.0f%%] %@", progress * 100.0, message]];
        }
    } output:^(NSString *line) {
        [self appendBuildOutputLine:line];
    } error:&preflightError];

    if (decision == GWPreflightDecisionProceed) {
        self.preflightInstalledPackages = [preflight installedPackages];
        if ([[preflight pendingPackages] count] > 0) {
            [self appendBuildOutputLine:[NSString stringWithFormat:
                @"Preflight: installed: %@",
                [[preflight pendingPackages] componentsJoinedByString:@", "]]];
        }
        if ([[preflight unresolvedHeaders] count] > 0) {
            [self appendBuildOutputLine:[NSString stringWithFormat:
                @"Preflight: headers not in database (ignored): %@",
                [[preflight unresolvedHeaders] componentsJoinedByString:@", "]]];
        }
        return YES;
    }

    NSString *detail = [preflightError localizedDescription] ?: @"Preflight cancelled.";
    [self appendBuildOutputLine:[NSString stringWithFormat:@"Preflight aborted: %@", detail]];
    if (_statusField) {
        [_statusField setStringValue:NSLocalizedString(@"Preflight failed; build aborted",
                                                       @"Status: preflight aborted build")];
    }
    if (_progressBar) [_progressBar stopAnimation:nil];
    return NO;
}

- (void)resolveDependenciesBeforeBuildInDirectory:(NSString *)dir
{
    if (!makefilePath) return;
    if (_dependencyResolved) return;

    NSString *mfContent = [NSString stringWithContentsOfFile:makefilePath
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (!mfContent) return;

    // Build reverse map: header prefix → repo name
    NSMutableDictionary *headerToRepo = [NSMutableDictionary dictionary];
    for (NSString *repo in [self gnustepInfo]) {
        NSDictionary *info = [[self gnustepInfo] objectForKey:repo];
        for (NSString *hdr in [info objectForKey:@"headers"]) {
            [headerToRepo setObject:repo forKey:hdr];
        }
    }

    NSMutableSet *neededRepos = [NSMutableSet set];

    // Scan ADDITIONAL_*_LIBS and LIBRARIES_DEPEND_UPON for -l<name> references
    NSString *target = [self productNameFromMakefile:makefilePath];
    NSMutableString *joined = [NSMutableString stringWithString:mfContent];
    [joined replaceOccurrencesOfString:@"\\\n"
                            withString:@" "
                               options:0
                                 range:NSMakeRange(0, [joined length])];
    NSArray *lines = [joined componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"ADDITIONAL_GUI_LIBS"] ||
            [trimmed hasPrefix:@"ADDITIONAL_OBJC_LIBS"] ||
            [trimmed hasPrefix:@"ADDITIONAL_TOOL_LIBS"] ||
            [trimmed hasPrefix:@"LIBRARIES_DEPEND_UPON"] ||
            [trimmed hasPrefix:[NSString stringWithFormat:@"%@_LIBRARIES_DEPEND_UPON", target]]) {
            NSString *val = [self parseVariableValue:trimmed];
            if ([val length] == 0) continue;
            NSArray *parts = [val componentsSeparatedByCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            for (NSString *part in parts) {
                if ([part hasPrefix:@"-l"]) {
                    NSString *libName = [part substringFromIndex:2];
                    NSString *repo = [headerToRepo objectForKey:libName];
                    if (repo) {
                        [neededRepos addObject:repo];
                    }
                }
            }
        }
    }

    // Also scan OBJC_FILES for #import "X/..." patterns
    NSArray *srcVars = @[@"OBJC_FILES", @"OBJCXX_FILES", @"C_FILES", @"CC_FILES",
                          @"CPP_FILES", @"CXX_FILES", @"OBJCPP_FILES"];
    NSMutableArray *sourceFiles = [NSMutableArray array];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        for (NSString *var in srcVars) {
            NSString *prefixed = target ? [NSString stringWithFormat:@"%@_%@", target, var] : nil;
            if ((prefixed && [trimmed hasPrefix:prefixed]) || [trimmed hasPrefix:var]) {
                NSString *val = [self parseVariableValue:trimmed];
                if ([val length] == 0) continue;
                NSArray *parts = [val componentsSeparatedByCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                for (NSString *part in parts) {
                    if ([part length] > 0 && ![part isEqualToString:@"\\"]) {
                        [sourceFiles addObject:part];
                    }
                }
            }
        }
    }
    for (NSString *src in sourceFiles) {
        NSString *srcPath = [dir stringByAppendingPathComponent:src];
        NSString *srcContent = [NSString stringWithContentsOfFile:srcPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:NULL];
        if (!srcContent) continue;
        NSScanner *sc = [NSScanner scannerWithString:srcContent];
        while (![sc isAtEnd]) {
            NSString *import;
            if ([sc scanUpToString:@"#import \"" intoString:NULL]) {
                if ([sc scanString:@"#import \"" intoString:NULL]) {
                    if ([sc scanUpToString:@"\"" intoString:&import]) {
                        NSRange slash = [import rangeOfString:@"/"];
                        if (slash.location != NSNotFound) {
                            NSString *prefix = [import substringToIndex:slash.location];
                            NSString *repo = [headerToRepo objectForKey:prefix];
                            if (repo) [neededRepos addObject:repo];
                        }
                    }
                }
            } else {
                // Also check @import X
                if ([sc scanUpToString:@"#import <" intoString:NULL]) {
                    if ([sc scanString:@"#import <" intoString:NULL]) {
                        if ([sc scanUpToString:@">" intoString:&import]) {
                            NSRange slash = [import rangeOfString:@"/"];
                            if (slash.location != NSNotFound) {
                                NSString *prefix = [import substringToIndex:slash.location];
                                NSString *repo = [headerToRepo objectForKey:prefix];
                                if (repo) [neededRepos addObject:repo];
                            }
                        }
                    }
                }
            }
            // Break if no progress to avoid infinite loop
            if ([sc scanLocation] == 0) break;
        }
    }

    // Check each needed repo: if not installed, download & build
    NSString *depDir = [dir stringByAppendingPathComponent:@"GNUstepDependencies"];
    for (NSString *repo in neededRepos) {
        NSDictionary *info = [[self gnustepInfo] objectForKey:repo];
        if (!info) continue;
        NSArray *headers = [info objectForKey:@"headers"];
        if ([headers count] == 0) continue;
        NSString *firstHeader = [headers objectAtIndex:0];
        NSString *headerDir = [@"/System/Library/Headers" stringByAppendingPathComponent:firstHeader];
        if ([[NSFileManager defaultManager] fileExistsAtPath:headerDir]) {
            NSLog(@"resolveDeps: %@ already installed at %@", repo, headerDir);
            continue; // Already installed system-wide
        }

        NSString *cloneDir = [depDir stringByAppendingPathComponent:repo];
        if ([[NSFileManager defaultManager] fileExistsAtPath:cloneDir]) {
            NSLog(@"resolveDeps: %@ already in GNUstepDependencies", repo);
            _dependencyResolved = YES;
            continue; // Already cloned
        }

        NSLog(@"resolveDeps: need to download %@", repo);
        [self buildGNUstepRepo:repo info:info dir:dir cloneDir:cloneDir];
    }
}

- (void)buildGNUstepRepo:(NSString *)repo info:(NSDictionary *)info dir:(NSString *)dir cloneDir:(NSString *)cloneDir
{
    NSString *org = [info objectForKey:@"org"];
    if (!org) org = @"gnustep";
    NSString *url = [NSString stringWithFormat:@"https://github.com/%@/%@", org, repo];

    NSString *depDir = [dir stringByAppendingPathComponent:@"GNUstepDependencies"];

    [_statusField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Downloading %@…", @"Status: downloading dependency"), repo]];
    [_logController appendLog:[NSString stringWithFormat:NSLocalizedString(@"=== Downloading %@ from %@ ===\n", @"Log: downloading"), repo, url]];

    [[NSFileManager defaultManager] createDirectoryAtPath:depDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    NSTask *gitTask = [[NSTask alloc] init];
    [gitTask setLaunchPath:toolPath(@"git")];
    [gitTask setArguments:@[@"clone", @"--depth=1", url, cloneDir]];
    [gitTask setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    [gitTask setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [gitTask launch];
        [gitTask waitUntilExit];
    } @catch (NSException *e) {
        [_logController appendLog:[NSString stringWithFormat:NSLocalizedString(@"git clone failed: %@\n", @"Log: git clone failed"), [e reason]]];
        return;
    }

    if ([gitTask terminationStatus] != 0) {
        [_logController appendLog:NSLocalizedString(@"git clone failed\n", @"Log: git clone failed")];
        return;
    }

    // Resolve transitive dependencies by scanning the dependency's source files
    NSString *depMf = [cloneDir stringByAppendingPathComponent:@"GNUmakefile"];
    NSString *depContent = [NSString stringWithContentsOfFile:depMf
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
    if (depContent) {
        // Derive the library's target name from the first header prefix
        NSString *targetName = nil;
        NSArray *headerPrefixes = [info objectForKey:@"headers"];
        if ([headerPrefixes count] > 0) {
            targetName = [headerPrefixes objectAtIndex:0];
        }

        NSMutableString *depJoined = [NSMutableString stringWithString:depContent];
        [depJoined replaceOccurrencesOfString:@"\\\n"
                                   withString:@" "
                                      options:0
                                        range:NSMakeRange(0, [depJoined length])];
        NSArray *depLines = [depJoined componentsSeparatedByString:@"\n"];
        for (NSString *line in depLines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            BOOL isLibDep = [trimmed hasPrefix:@"LIBRARIES_DEPEND_UPON"] ||
                (targetName && [trimmed hasPrefix:[NSString stringWithFormat:@"%@_LIBRARIES_DEPEND_UPON", targetName]]);
            BOOL isAddLib = [trimmed hasPrefix:@"ADDITIONAL_GUI_LIBS"] ||
                [trimmed hasPrefix:@"ADDITIONAL_OBJC_LIBS"] ||
                [trimmed hasPrefix:@"ADDITIONAL_TOOL_LIBS"];
            if (isLibDep || isAddLib) {
                NSString *val = [self parseVariableValue:trimmed];
                if ([val length] == 0) continue;
                NSArray *parts = [val componentsSeparatedByCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                for (NSString *part in parts) {
                    if ([part hasPrefix:@"-l"]) {
                        NSString *libName = [part substringFromIndex:2];
                        NSDictionary *headerToRepo = [NSMutableDictionary dictionary];
                        for (NSString *r in [self gnustepInfo]) {
                            NSDictionary *inf = [[self gnustepInfo] objectForKey:r];
                            for (NSString *hdr in [inf objectForKey:@"headers"]) {
                                [headerToRepo setValue:r forKey:hdr];
                            }
                        }
                        NSString *depRepo = [headerToRepo objectForKey:libName];
                        if (depRepo && ![depRepo isEqualToString:repo]) {
                            NSString *depDir2 = [dir stringByAppendingPathComponent:@"GNUstepDependencies"];
                            NSString *depCloneDir = [depDir2 stringByAppendingPathComponent:depRepo];
                            NSDictionary *depInfo = [[self gnustepInfo] objectForKey:depRepo];
                            if (depInfo && ![[NSFileManager defaultManager] fileExistsAtPath:depCloneDir]) {
                                [_logController appendLog:[NSString stringWithFormat:NSLocalizedString(@"=== Resolving transitive dependency %@ ===\n", @"Log: resolving transitive dep"), depRepo]];
                                [self buildGNUstepRepo:depRepo info:depInfo dir:dir cloneDir:depCloneDir];
                            }
                        }
                    }
                }
            }
        }
    }

    [_statusField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Building %@…", @"Status: building dependency"), repo]];
    [_logController appendLog:[NSString stringWithFormat:NSLocalizedString(@"=== Building %@ ===\n", @"Log: building dep"), repo]];

    // Run configure if it exists
    NSString *configure = [cloneDir stringByAppendingPathComponent:@"configure"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:configure]) {
        [_logController appendLog:[NSString stringWithFormat:NSLocalizedString(@"=== Running configure in %@ ===\n", @"Log: running configure in dep"), repo]];
        NSPipe *cOut = [NSPipe pipe];
        NSTask *cfgTask = [[NSTask alloc] init];
        [cfgTask setCurrentDirectoryPath:cloneDir];
        [cfgTask setLaunchPath:configure];
        [cfgTask setArguments:@[]];
        [cfgTask setEnvironment:[[NSProcessInfo processInfo] environment]];
        [cfgTask setStandardOutput:cOut];
        [cfgTask setStandardError:cOut];
        @try {
            [cfgTask launch];
            [cfgTask waitUntilExit];
            NSData *cData = [[cOut fileHandleForReading] readDataToEndOfFile];
            if ([cData length] > 0) {
                NSString *cStr = [[NSString alloc] initWithData:cData encoding:NSUTF8StringEncoding];
                [_logController appendLog:cStr];
            }
        } @catch (NSException *e) {
            [_logController appendLog:[NSString stringWithFormat:NSLocalizedString(@"configure failed: %@\n", @"Log: configure failed"), [e reason]]];
        }
    }

    NSString *gmakePath = toolPath(@"gmake");
    if (!gmakePath) gmakePath = toolPath(@"make");
    if (!gmakePath) return;

    // Build include/lib path from other deps in GNUstepDependencies
    NSString *depDir2 = [dir stringByAppendingPathComponent:@"GNUstepDependencies"];
    NSMutableDictionary *buildEnv = [[[NSProcessInfo processInfo] environment] mutableCopy];
    NSMutableString *depCppFlags = [NSMutableString string];
    NSMutableString *depLdFlags = [NSMutableString string];
    NSFileManager *fm2 = [NSFileManager defaultManager];
    NSArray *otherDeps = [fm2 contentsOfDirectoryAtPath:depDir2 error:NULL];
    for (NSString *od in otherDeps) {
        if ([od isEqualToString:repo]) continue;
        NSString *odir = [depDir2 stringByAppendingPathComponent:od];
        NSArray *chk = @[
            [odir stringByAppendingPathComponent:@"Headers"],
            odir
        ];
        for (NSString *hd in chk) {
            if ([fm2 fileExistsAtPath:hd]) {
                NSArray *cnt = [fm2 contentsOfDirectoryAtPath:hd error:NULL];
                for (NSString *f in cnt) {
                    if ([[f pathExtension] isEqualToString:@"h"]) {
                        if ([depCppFlags length] > 0) [depCppFlags appendString:@" "];
                        [depCppFlags appendFormat:@"-I%@", hd];
                        break;
                    }
                }
                break;
            }
        }
        // Add library path
        NSString *oDir = [odir stringByAppendingPathComponent:@"obj"];
        if ([fm2 fileExistsAtPath:oDir]) {
            if ([depLdFlags length] > 0) [depLdFlags appendString:@" "];
            [depLdFlags appendFormat:@"-L%@", oDir];
        }
    }
    if ([depCppFlags length] > 0) {
        [buildEnv setObject:depCppFlags forKey:@"ADDITIONAL_CPPFLAGS"];
    }
    if ([depLdFlags length] > 0) {
        [buildEnv setObject:depLdFlags forKey:@"ADDITIONAL_LDFLAGS"];
    }

    // Add this dependency to progress tracking
    NSString *depTarget = [self productNameFromMakefile:depMf];
    NSInteger depCount = [self countSourceFilesInMakefile:depMf
                                                   target:depTarget
                                                    depth:0];
    [_projectFileCounts addObject:@(depCount)];
    [_projectCompiledCounts addObject:@(0)];
    _currentProjectIndex = [_projectFileCounts count] - 1;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger totalEstimate = [self totalEstimatedFiles];
        [_progressBar setIndeterminate:NO];
        [_progressBar setMinValue:0];
        [_progressBar setMaxValue:totalEstimate > 0 ? totalEstimate : 1];
        [_progressBar setDoubleValue:0];
    });

    NSPipe *bOut = [NSPipe pipe];
    NSPipe *bErr = [NSPipe pipe];

    NSTask *buildTask2 = [[NSTask alloc] init];
    [buildTask2 setCurrentDirectoryPath:cloneDir];
    [buildTask2 setLaunchPath:gmakePath];
    [buildTask2 setArguments:@[@"-f", @"GNUmakefile", @"clean", @"all"]];
    [buildTask2 setEnvironment:buildEnv];
    [buildTask2 setStandardOutput:bOut];
    [buildTask2 setStandardError:bErr];
    @try {
        [buildTask2 launch];
        [buildTask2 waitUntilExit];
    } @catch (NSException *e) {
        [_logController appendLog:[NSString stringWithFormat:NSLocalizedString(@"build failed: %@\n", @"Log: build failed"), [e reason]]];
        return;
    }

    NSData *outData = [[bOut fileHandleForReading] readDataToEndOfFile];
    if ([outData length] > 0) {
        NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
        [_logController appendLog:outStr];
        write(STDOUT_FILENO, [outData bytes], [outData length]);

        // Count "Compiling file" lines for progress tracking
        NSUInteger compiled = 0;
        NSUInteger pos = 0;
        while (pos < [outStr length]) {
            NSRange r = [outStr rangeOfString:@"Compiling file "
                                     options:0
                                       range:NSMakeRange(pos, [outStr length] - pos)];
            if (r.location == NSNotFound) break;
            compiled++;
            pos = r.location + r.length;
        }
        if (compiled > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateProgressForCompiledFiles:compiled taskRunning:NO];
            });
        }
    }
    NSData *errData = [[bErr fileHandleForReading] readDataToEndOfFile];
    if ([errData length] > 0) {
        NSString *errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        [_logController appendLog:errStr];
        write(STDERR_FILENO, [errData bytes], [errData length]);
    }

    if ([buildTask2 terminationStatus] != 0) {
        [_logController appendLog:NSLocalizedString(@"build failed\n", @"Log: build failed")];
        return;
    }

    // Create header prefix subdirectory with symlinks so imports like
    // #import "WebServices/GWSService.h" resolve correctly
    NSArray *prefixes = [info objectForKey:@"headers"];
    for (NSString *prefix in prefixes) {
        NSString *hdrLinkDir = [cloneDir stringByAppendingPathComponent:prefix];
        [[NSFileManager defaultManager] createDirectoryAtPath:hdrLinkDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        NSArray *hFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:cloneDir error:NULL];
        for (NSString *f in hFiles) {
            if ([[f pathExtension] isEqualToString:@"h"] || [[f pathExtension] isEqualToString:@"a"]) {
                NSString *linkPath = [hdrLinkDir stringByAppendingPathComponent:f];
                NSString *target = [@"../" stringByAppendingPathComponent:f];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:linkPath
                                                     withDestinationPath:target
                                                                   error:NULL];
            }
        }
    }

    [_logController appendLog:[NSString stringWithFormat:NSLocalizedString(@"=== %@ built in %@ ===\n", @"Log: dep built at path"), repo, cloneDir]];
    _dependencyResolved = YES;
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    if (sender != _window) return YES;

    BOOL busy = (buildTask && [buildTask isRunning]) || (installTask && [installTask isRunning]);
    if (!busy) return YES;

    closeCount++;
    if (closeCount == 1) {
        [closeTimer invalidate];
        closeTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                      target:self
                                                    selector:@selector(closeTimerFired:)
                                                    userInfo:nil
                                                     repeats:NO];
        if (_statusField) {
            [_statusField setStringValue:NSLocalizedString(@"Press Close again to force quit.", @"Status: hint to force quit")];
        }
        return NO;
    }

    // Second attempt: show dialog immediately
    [closeTimer invalidate];
    closeTimer = nil;
    closeCount = 0;

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"Force Quit?", @"Alert title: force quit?")];
    [alert setInformativeText:NSLocalizedString(@"Build is still in progress. Force quit?", @"Alert: confirm force quit")];
    [alert addButtonWithTitle:NSLocalizedString(@"Force Quit", @"Button: force quit")];
    [alert addButtonWithTitle:NSLocalizedString(@"Wait", @"Button: wait")];
    NSInteger result = [alert runModal];
    if (result == NSAlertFirstButtonReturn) {
        if (buildTask && [buildTask isRunning]) [buildTask terminate];
        if (installTask && [installTask isRunning]) [installTask terminate];
        return YES;
    }
    if (_statusField) {
        [_statusField setStringValue:NSLocalizedString(@"Building…", @"Status: building (no name)")];
    }
    return NO;
}

- (void)closeTimerFired:(NSTimer *)timer
{
    closeTimer = nil;
    closeCount = 0;

    BOOL busy = (buildTask && [buildTask isRunning]) || (installTask && [installTask isRunning]);
    if (!busy) {
        [_window close];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"Force Quit?", @"Alert title: force quit?")];
    [alert setInformativeText:NSLocalizedString(@"Build is still in progress. Force quit?", @"Alert: confirm force quit")];
    [alert addButtonWithTitle:NSLocalizedString(@"Force Quit", @"Button: force quit")];
    [alert addButtonWithTitle:NSLocalizedString(@"Wait", @"Button: wait")];
    NSInteger result = [alert runModal];
    if (result == NSAlertFirstButtonReturn) {
        if (buildTask && [buildTask isRunning]) [buildTask terminate];
        if (installTask && [installTask isRunning]) [installTask terminate];
        [_window close];
    } else {
        if (_statusField) {
            [_statusField setStringValue:NSLocalizedString(@"Building…", @"Status: building (no name)")];
        }
    }
}

- (void)windowWillClose:(NSNotification *)notification
{
    NSWindow *closingWindow = [notification object];
    if (closingWindow == _window) {
        [closeTimer invalidate];
        closeTimer = nil;
        closeCount = 0;
        [self cleanupTempDir];
        if (buildTask && [buildTask isRunning]) {
            [buildTask terminate];
        }
        if (installTask && [installTask isRunning]) {
            [installTask terminate];
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [self quitCleanly];
    } else if (closingWindow == [_logController window]) {
        BOOL busy = (buildTask && [buildTask isRunning]) || (installTask && [installTask isRunning]);
        if (!busy) {
            [self quitCleanly];
        }
    }
}

@end
