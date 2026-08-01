/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OnDemandController implementation.
 *
 * Flow:
 *   setupFromPlist -> reads Install.plist from bundle
 *   showWindow -> creates and displays progress UI
 *   performInstallAndLaunch ->
 *     1. Check if postinstall_command exists
 *     2. If yes -> launch it directly
 *     3. If no  -> install packages via GWPackageManager, then launch
 */

#import "OnDemandController.h"
#import "../GWSystemCommandExecutor.h"

#pragma mark - Constants (derived from AppearanceMetrics.h)

// HIG metrics (see AppearanceMetrics.h)
static const CGFloat kWinWidth = 400.0;
static const CGFloat kSideMargin = 24.0;
static const CGFloat kBottomMargin = 20.0;
static const CGFloat kTopMargin = 15.0;
static const CGFloat kBtnHeight = 20.0;
static const CGFloat kBtnWide = 100.0;
static const CGFloat kBtnHSpace = 10.0;          // METRICS_BUTTON_HORIZ_INTERSPACE
static const CGFloat kBarHeight = 20.0;
static const CGFloat kLineHeight = 18.0;
static const CGFloat kIconSide = 64.0;            // METRICS_ICON_SIDE
static const CGFloat kIconLeft = 24.0;            // METRICS_ICON_LEFT
static const CGFloat kTextLeft = 104.0;           // METRICS_TEXT_LEFT = 24 + 64 + 16
static const CGFloat kSpace8 = 8.0;               // METRICS_SPACE_8
static const CGFloat kSpace16 = 16.0;              // METRICS_SPACE_16

#pragma mark - ODLogWindowController

@interface ODLogWindowController : NSWindowController
{
  NSScrollView *_scrollView;
  NSTextView *_logView;
}
- (void)appendLog:(NSString *)text;
- (void)clearLog;
@end

@implementation ODLogWindowController

- (instancetype)init
{
  NSRect screenFrame = [[NSScreen mainScreen] frame];
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
  [logWindow setTitle:@"Installer Log"];
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

#pragma mark - OnDemandController

@implementation OnDemandController
{
  BOOL _isTerminating;
  double _totalDownloadBytes;
  double _downloadedBytes;
  CGFloat _lastFetchPct;
  NSUInteger _completedFetchFiles;
}

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _pm = [[GWPackageManager alloc] initWithBackend:nil];
      _isTerminating = NO;
    }
  return self;
}

/// Resolve the actual .app bundle path from argv[0] so symlinked
/// placeholders load their own Resources/Install.plist rather than
/// the symlink target's bundle (OnDemand.app).
- (NSString *)_actualBundlePath
{
  NSString *arg0 = [[[NSProcessInfo processInfo] arguments] firstObject];
  if (arg0)
    {
      NSString *absPath = [arg0 stringByStandardizingPath];
      NSString *dir = absPath;
      while (dir && ![dir isEqualToString:@"/"])
        {
          if ([[dir pathExtension] isEqualToString:@"app"])
            return dir;
          dir = [dir stringByDeletingLastPathComponent];
        }
    }
  return [[NSBundle mainBundle] bundlePath];
}

#pragma mark - Plist Setup

- (BOOL)setupFromPlist
{
  NSString *appPath = [self _actualBundlePath];
  _plistPath = [appPath stringByAppendingPathComponent:@"Resources/Install.plist"];
  NSLog(@"OnDemand -> setupFromPlist: appPath=%@, plist=%@", appPath, _plistPath);

  if (!_plistPath)
    {
      NSLog(@"OnDemand [FAIL] setupFromPlist: Install.plist not found at %@", _plistPath);
      return NO;
    }

  _spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:_plistPath
                                                   specType:GWPackageInstallSpecTypeInstall
                                                      error:nil];
  if (!_spec)
    {
      NSLog(@"OnDemand [FAIL] setupFromPlist: failed to parse %@", _plistPath);
      return NO;
    }

  // App name from the .app bundle directory (e.g., "Krita.app" -> "Krita")
  _appName = [[appPath lastPathComponent] stringByDeletingPathExtension];
  if ([_appName length] == 0)
    _appName = @"Application";
  NSLog(@"OnDemand [OK] setupFromPlist: app=%@ packages=%@ command=%@",
        _appName, [_spec packages], [_spec postCommand]);

  return YES;
}

#pragma mark - Direct File Install

static NSString *_detectPackageFormat(NSString *path)
{
  NSString *ext = [path pathExtension];
  NSString *name = [path lastPathComponent];

  if ([ext isEqualToString:@"deb"])
    return @"deb";

  /* FreeBSD pkg: .txz (tar.xz), .tbz (tar.bz2) */
  if ([ext isEqualToString:@"txz"] || [ext isEqualToString:@"tbz"])
    return @"freebsd";

  /* OpenBSD pkg_add: .tgz */
  if ([ext isEqualToString:@"tgz"])
    return @"openbsd";

  /* Arch Linux: .pkg.tar.zst / .pkg.tar.xz / .pkg.tar.gz */
  if ([name hasSuffix:@".pkg.tar.zst"]) return @"arch";
  if ([name hasSuffix:@".pkg.tar.xz"])  return @"arch";
  if ([name hasSuffix:@".pkg.tar.gz"])  return @"arch";

  return nil;
}

- (BOOL)setupFromFile:(NSString *)path
{
  _isDirectInstall = YES;
  _directFilePath = [path copy];
  _directFormat   = [_detectPackageFormat(path) copy];

  if (!_directFormat)
    {
      NSLog(@"OnDemand [FAIL] setupFromFile: unknown format for %@", path);
      return NO;
    }

  _appName = [[path lastPathComponent] copy];
  NSLog(@"OnDemand -> setupFromFile: %@ (format: %@)", path, _directFormat);

  return YES;
}

/* Run a dry-run command with a 30s timeout, return stdout or nil */
static NSString *_runCmd(NSString *path, NSArray *args)
{
  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:path];
  [t setArguments:args];
  NSPipe *p = [NSPipe pipe];
  [t setStandardOutput:p];
  [t setStandardError:[NSPipe pipe]];
  [t launch];

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    [t waitUntilExit];
    dispatch_semaphore_signal(sem);
  });

  NSString *result = nil;
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC)) == 0)
    {
      if ([t terminationStatus] == 0)
        {
          NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
          result = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
    }
  else
    {
      [t terminate];
      [t waitUntilExit];
    }
  dispatch_release(sem);
  return result;
}

/* Parse the dry-run output and show a confirmation dialog.
   Always shows what will happen and what will be downloaded.
   Returns YES if the user clicked "Install", NO for "Cancel". */
static BOOL _confirmInstall(NSString *pkgName, NSString *filePath, NSString *fmt)
{
  NSString *detail = @"";

  if ([fmt isEqualToString:@"deb"])
    {
      /* Debian/Ubuntu: apt-get --simulate install ./<file> shows the local
         package plus any dependencies that would be downloaded */
      NSString *out = _runCmd(@"/usr/bin/apt-get",
        @[@"--simulate", @"install", [@"./" stringByAppendingPathComponent:filePath]]);
      if (out)
        {
          NSString *summary = @"";
          NSString *dlSize = @"";
          for (NSString *line in [out componentsSeparatedByString:@"\n"])
            {
              if ([line rangeOfString:@"upgraded"].location != NSNotFound ||
                  [line rangeOfString:@"newly installed"].location != NSNotFound)
                summary = [line stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceCharacterSet]];
              if ([line hasPrefix:@"Need to get"])
                dlSize = [line stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceCharacterSet]];
            }
          if ([dlSize length] > 0)
            detail = [NSString stringWithFormat:@"\n\n%@\n%@",
              summary, dlSize];
          else
            detail = @"\n\nNo additional packages will be downloaded — the package is self-contained.";
        }
    }
  else if ([fmt isEqualToString:@"arch"])
    {
      /* Arch: pacman -U --print shows what -U would do */
      NSString *out = _runCmd(@"/usr/bin/pacman", @[@"-U", @"--print", filePath]);
      if (out && [out length] > 0)
        {
          NSUInteger count = 0;
          for (NSString *line in [out componentsSeparatedByString:@"\n"])
            if ([line length] > 0) count++;
          detail = [NSString stringWithFormat:
            @"\n\nThis will install/affect %lu package(s).",
            (unsigned long)count];
        }
      else
        detail = @"\n\nNo additional packages will be downloaded.";
    }
  else
    {
      /* FreeBSD/OpenBSD: pkg add / pkg_add install the local file.
         Dependencies are resolved from repositories at install time. */
      detail = @"\n\nDependencies will be resolved by the system package manager.";
    }

  NSString *info = [NSString stringWithFormat:
    @"The package “%@” will be installed using the system package manager.\n"
    @"The file itself is already downloaded.%@",
    pkgName, detail];

  /* Show confirmation dialog */
  __block BOOL result = NO;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:[NSString stringWithFormat:@"Install %@?", pkgName]];
    [alert setInformativeText:info];
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn)
      result = YES;
    dispatch_semaphore_signal(sem);
  });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  dispatch_release(sem);
  return result;
}

/* Query the just-installed package's file list for .desktop entries and wrap them */
static void _wrapPackageDesktopFiles(NSString *pkgName, NSString *fmt)
{
  NSString *listCmd = nil;
  if ([fmt isEqualToString:@"deb"])
    listCmd = [NSString stringWithFormat:@"dpkg -L %@ 2>/dev/null | grep '\\.desktop$'", pkgName];
  else if ([fmt isEqualToString:@"arch"])
    listCmd = [NSString stringWithFormat:@"pacman -Ql %@ 2>/dev/null | grep '\\.desktop$' | awk '{print $2}'", pkgName];
  else if ([fmt isEqualToString:@"freebsd"])
    listCmd = [NSString stringWithFormat:@"pkg info -l %@ 2>/dev/null | grep '\\.desktop$'", pkgName];
  else if ([fmt isEqualToString:@"openbsd"])
    listCmd = [NSString stringWithFormat:@"pkg_info -L %@ 2>/dev/null | grep '\\.desktop$' | sed 's/^.* //'", pkgName];
  else
    return;

  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"/bin/sh"];
  [t setArguments:@[@"-c", listCmd]];
  NSPipe *p = [NSPipe pipe];
  [t setStandardOutput:p];
  [t setStandardError:[NSPipe pipe]];
  [t launch];
  NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
  [t waitUntilExit];
  if ([t terminationStatus] != 0) return;

  NSString *output = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  for (NSString *line in [output componentsSeparatedByString:@"\n"])
    {
      NSString *df = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([df hasSuffix:@".desktop"] && [[NSFileManager defaultManager] fileExistsAtPath:df])
        {
          NSLog(@"OnDemand: wrapping %@", [df lastPathComponent]);
          NSTask *w = [[NSTask alloc] init];
          [w setLaunchPath:@"/Local/Library/Tools/appwrap"];
          [w setArguments:@[@"-f", df]];
          [w launch];
          [w waitUntilExit];
        }
    }
}

/* Extract package name from a package file */
static NSString *_packageNameFromFile(NSString *path, NSString *fmt)
{
  NSString *cmd = nil;
  if ([fmt isEqualToString:@"deb"])
    cmd = [NSString stringWithFormat:@"dpkg --info '%@' 2>/dev/null | grep '^ Package:' | awk '{print $2}'", path];
  else if ([fmt isEqualToString:@"arch"])
    cmd = [NSString stringWithFormat:@"pacman -Qp '%@' 2>/dev/null | awk '{print $1}'", path];
  else if ([fmt isEqualToString:@"freebsd"])
    cmd = [NSString stringWithFormat:@"pkg info -F '%@' 2>/dev/null | grep '^Name:' | awk '{print $2}'", path];
  else if ([fmt isEqualToString:@"openbsd"])
    cmd = [NSString stringWithFormat:@"pkg_info -F '%@' 2>/dev/null | grep '^Package:' | awk '{print $2}'", path];
  else
    return nil;

  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"/bin/sh"];
  [t setArguments:@[@"-c", cmd]];
  NSPipe *p = [NSPipe pipe];
  [t setStandardOutput:p];
  [t setStandardError:[NSPipe pipe]];
  [t launch];
  NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
  [t waitUntilExit];
  int rc = [t terminationStatus];
  if (rc != 0) return nil;

  NSString *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  return [[out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0
    ? [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
}

- (void)performDirectInstall
{
  if (!_directFilePath || !_directFormat) return;

  /* Ask for confirmation first. Only show the progress window after the
     user confirms. Runs on a background thread; _confirmInstall shows the
     modal alert on the main thread and waits for the answer. */
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString *pkgName = [_directFilePath lastPathComponent];
    if (!_confirmInstall(pkgName, _directFilePath, _directFormat))
      {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self _finishWithCancel];
        });
        return;
      }

    /* User confirmed — now show the progress window and install */
    dispatch_async(dispatch_get_main_queue(), ^{
      [self showWindow];
      [self installDidProgress:0.0 message:@"Installing package..."];
    });

    setenv("SUDO_ASKPASS", "/bin/false", 1);
    GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:nil];
    BOOL ok = [pm installPackages:@[]
                   localFilePaths:@[_directFilePath]
                         progress:self
                            error:nil];

    if (ok)
      {
        NSString *installedName = _packageNameFromFile(_directFilePath, _directFormat);
        if (installedName)
          {
            [self installDidProgress:0.95 message:@"Creating application wrappers..."];
            _wrapPackageDesktopFiles(installedName, _directFormat);
          }
      }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (ok)
        {
          [self installDidProgress:1.0 message:@"Installation complete"];
          [self _finishWithSuccess];
        }
      else
        {
          [self installDidProgress:1.0 message:@"Installation failed"];
          [self _finishWithError:
            @"Package installation failed.\n\nCheck the installer log for details."];
        }
    });
  });
}

- (void)showError:(NSString *)message
{
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:@"Installation Error"];
  [alert setInformativeText:message];
  [alert addButtonWithTitle:@"OK"];
  [alert runModal];
  [NSApp terminate:nil];
}

- (void)_finishWithCancel
{
  [NSApp terminate:nil];
}

- (void)_finishWithSuccess
{
  if (_isDirectInstall)
    {
      /* Try to find and offer to launch the installed app */
      NSString *guessed = [_directFilePath lastPathComponent];
      NSString *binName = [guessed stringByDeletingPathExtension];
      NSArray *parts = [binName componentsSeparatedByString:@"_"];
      NSString *candidate = [parts count] > 0 ? parts[0] : binName;
      _launchPath = [self _which:candidate];
      if (!_launchPath)
        _launchPath = [self _which:[candidate stringByAppendingString:@"-stable"]];
      if (_launchPath)
        {
          [_installButton setTitle:@"Launch"];
          [_installButton setAction:@selector(launchFoundApp)];
          [_installButton setTarget:self];
        }
      else
        {
          [_installButton setTitle:@"Close"];
          [_installButton setAction:@selector(closeWindow:)];
          [_installButton setTarget:self];
        }
    }
  else
    {
      [_installButton setTitle:@"Close"];
      [_installButton setAction:@selector(closeWindow:)];
      [_installButton setTarget:self];
    }
  [_cancelButton setTitle:@"Close"];
  [_cancelButton setAction:@selector(closeWindow:)];
  [_cancelButton setTarget:self];
}

- (IBAction)launchFoundApp
{
  if (_launchPath)
    {
      [[NSWorkspace sharedWorkspace] launchApplication:_launchPath];
    }
  [NSApp terminate:nil];
}

- (NSString *)_which:(NSString *)name
{
  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"/usr/bin/which"];
  [t setArguments:@[name]];
  NSPipe *p = [NSPipe pipe];
  [t setStandardOutput:p];
  [t launch];
  NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
  [t waitUntilExit];
  int rc = [t terminationStatus];
  if (rc != 0) return nil;
  NSString *r = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  return [r stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)_finishWithError:(NSString *)errorDetail
{
  [_installButton setTitle:@"Close"];
  [_installButton setAction:@selector(closeWindow:)];
  [_installButton setTarget:self];
  [_cancelButton setEnabled:NO];
  [self showError:errorDetail];
}

- (IBAction)closeWindow:(id)sender
{
  (void)sender;
  [NSApp terminate:nil];
}

#pragma mark - Window Setup

- (void)showWindow
{
  if (_window) return; /* already showing */
  CGFloat cx = kSideMargin;
  CGFloat contentW = kWinWidth - 2 * kSideMargin;
  CGFloat textW = kWinWidth - kSideMargin - kTextLeft;       // 272

  // Description text
  NSString *desc;
  NSString *installTitle;
  if (_isDirectInstall)
    {
      NSString *fmt = _directFormat ?: @"package";
      desc = [NSString stringWithFormat:
        @"Install %@ (%@ format).\n\nThe package will be installed using the system package manager.",
        _appName, fmt];
      installTitle = @"Install";
    }
  else
    {
      desc = [NSString stringWithFormat:
        @"%@ is not yet available on this system and needs to be downloaded from the Internet.\nWould you like to download it now?", _appName];
      installTitle = @"Download";
    }

  // Calculate actual text height: measure via attributed string
  NSFont *descFont = [NSFont systemFontOfSize:11.0];
  NSAttributedString *as = [[NSAttributedString alloc] initWithString:desc
                                                           attributes:@{ NSFontAttributeName: descFont }];
  NSRect textBounds = [as boundingRectWithSize:NSMakeSize(textW, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin];
  // Add padding for NSTextField text container insets
  CGFloat totalDescH = ceil(textBounds.size.height) + 4.0;

  // Window height (bottom-up):
  // bottom(20) + btn(20) + gap(16) + desc(mm) + gap(8) + icon(64) + top(15)
  CGFloat winH = kBottomMargin + kBtnHeight + kSpace16
               + totalDescH + kSpace8 + kIconSide + kTopMargin;

  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWinWidth, winH)
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                          backing:NSBackingStoreBuffered
                                            defer:NO];

  CGFloat y = kBottomMargin;

  // ── Bottom row: Cancel + Download (right-aligned, Cancel left of default) ──
  CGFloat btnRight = kWinWidth - kSideMargin;
  CGFloat downloadX = btnRight - kBtnWide;
  CGFloat cancelX  = downloadX - kBtnHSpace - kBtnWide;

  _cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(cancelX, y, kBtnWide, kBtnHeight)];
  [_cancelButton setTitle:@"Cancel"];
  [_cancelButton setTarget:self];
  [_cancelButton setAction:@selector(cancelClicked:)];
  [_cancelButton setKeyEquivalent:@"\e"];
  [[_window contentView] addSubview:_cancelButton];

  _installButton = [[NSButton alloc] initWithFrame:NSMakeRect(downloadX, y, kBtnWide, kBtnHeight)];
  [_installButton setTitle:installTitle];
  [_installButton setTarget:self];
  [_installButton setAction:@selector(installClicked:)];
  [_installButton setKeyEquivalent:@"\r"];
  [[_window contentView] addSubview:_installButton];

  y += kBtnHeight + kSpace16;

  // ── Description ──
  _descriptionField = [[NSTextField alloc] initWithFrame:NSMakeRect(kTextLeft, y, contentW - kTextLeft + cx, totalDescH)];
  [_descriptionField setStringValue:desc];
  [_descriptionField setBezeled:NO];
  [_descriptionField setDrawsBackground:NO];
  [_descriptionField setEditable:NO];
  [_descriptionField setSelectable:NO];
  [_descriptionField setAlignment:NSTextAlignmentLeft];
  [_descriptionField setFont:descFont];
  [[_descriptionField cell] setLineBreakMode:NSLineBreakByWordWrapping];
  [[_window contentView] addSubview:_descriptionField];

  y += totalDescH + kSpace8;

  // ── App icon + name ──
  _iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(kIconLeft, y, kIconSide, kIconSide)];
  [_iconView setImageFrameStyle:NSImageFrameNone];
  NSString *appPath = [self _actualBundlePath];
  NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:appPath];
  if (icon) [_iconView setImage:icon];
  [[_window contentView] addSubview:_iconView];

  CGFloat nameX = kTextLeft;
  CGFloat nameW = btnRight - kTextLeft;
  NSRect nr = NSMakeRect(nameX, y + (kIconSide - kLineHeight) / 2, nameW, kLineHeight);
  NSTextField *nf = [[NSTextField alloc] initWithFrame:nr];
  [nf setStringValue:_appName ?: @""];
  [nf setBezeled:NO];
  [nf setDrawsBackground:NO];
  [nf setEditable:NO];
  [nf setSelectable:NO];
  [nf setFont:[NSFont systemFontOfSize:13.0]];
  [[_window contentView] addSubview:nf];

  // ── Progress UI ──
  if (_isDirectInstall)
    {
      // Direct install: auto-start, hide confirmation UI, show progress
      [_descriptionField setHidden:YES];
      [_installButton setHidden:YES];
      [self _showProgressBar];
    }
  else
    {
      _progressBar = nil;
      _statusField = nil;
    }

  [_window setTitle:_appName];
  [_window center];

  // Defer display to next run loop iteration to avoid window system crashes
  dispatch_async(dispatch_get_main_queue(), ^{
    [_window orderFront:nil];
  });
}

#pragma mark - Progress Handler

- (void)installDidProgress:(float)progress message:(NSString *)message
{
  NSLog(@"OnDemand -> installDidProgress: %.0f%% — %@", progress * 100, message);
  dispatch_async(dispatch_get_main_queue(), ^{
    [_statusField setStringValue:message ?: @""];

    // Switch to indeterminate during long operations (no real progress info)
    if (progress > 0.1f && progress < 1.0f && ![_progressBar isIndeterminate])
      {
        [_progressBar setIndeterminate:YES];
        [_progressBar startAnimation:nil];
      }
    else if (progress >= 1.0f && [_progressBar isIndeterminate])
      {
        [_progressBar stopAnimation:nil];
        [_progressBar setIndeterminate:NO];
        [_progressBar setDoubleValue:1.0];
      }
    else if (![_progressBar isIndeterminate])
      {
        [_progressBar setDoubleValue:(double)progress];
      }

    [_progressBar displayIfNeeded];
  });
}

#pragma mark - Actions

- (void)cancelClicked:(id)sender
{
  NSLog(@"OnDemand: User cancelled");
  if (_isTerminating) return;
  _isTerminating = YES;
  [_window close];
}

- (void)_showProgressBar
{
  CGFloat cx = kSideMargin;
  CGFloat contentW = kWinWidth - 2 * kSideMargin;
  CGFloat progY  = kBottomMargin + kBtnHeight + kSpace16;
  CGFloat statY  = progY + kBarHeight + kSpace8;

  _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(kTextLeft, progY, contentW - kTextLeft + cx, kBarHeight)];
  [_progressBar setStyle:NSProgressIndicatorBarStyle];
  [_progressBar setIndeterminate:NO];
  [_progressBar setMinValue:0.0];
  [_progressBar setMaxValue:1.0];
  [_progressBar setDoubleValue:0.0];
  [[_window contentView] addSubview:_progressBar];

  _statusField = [[NSTextField alloc] initWithFrame:NSMakeRect(kTextLeft, statY, contentW - kTextLeft + cx, kLineHeight)];
  [_statusField setStringValue:@"Preparing…"];
  [_statusField setBezeled:NO];
  [_statusField setDrawsBackground:NO];
  [_statusField setEditable:NO];
  [_statusField setSelectable:NO];
  [_statusField setAlignment:NSTextAlignmentLeft];
  [[_window contentView] addSubview:_statusField];
}

- (void)installClicked:(id)sender
{
  if (_isDirectInstall)
    {
      NSLog(@"OnDemand -> installClicked: direct install");
      [_descriptionField setHidden:YES];
      [_installButton setHidden:YES];
      [self _showProgressBar];
      [self performDirectInstall];
      return;
    }

  NSLog(@"OnDemand -> installClicked: user confirmed download");

  // Reset progress tracking counters
  _totalDownloadBytes = 0.0;
  _downloadedBytes = 0.0;
  _lastFetchPct = -1.0;
  _completedFetchFiles = 0;

  // Switch from confirmation to progress UI
  [_descriptionField setHidden:YES];
  [_installButton setHidden:YES];

  [self _showProgressBar];
  [[_window contentView] addSubview:_statusField];

  // Cancel button in lower-right
  CGFloat btnRight = kWinWidth - kSideMargin;
  [_cancelButton setFrameOrigin:NSMakePoint(
    btnRight - kBtnWide, kBottomMargin)];

  [_window setTitle:[NSString stringWithFormat:@"Downloading %@", _appName]];

  // Start download on background thread
  [self performInstallAndLaunch];
}

#pragma mark - Command Checking

- (BOOL)_commandExists:(NSString *)command
{
  if (!command || [command length] == 0)
    {
      NSLog(@"OnDemand -> _commandExists: (empty) -> NO");
      return NO;
    }

  // If it's an absolute path, check directly
  if ([command hasPrefix:@"/"])
    {
      BOOL exists = [[NSFileManager defaultManager] isExecutableFileAtPath:command];
      NSLog(@"OnDemand -> _commandExists: absolute path %@ -> %s", command, exists ? "YES" : "NO");
      return exists;
    }

  // Search PATH via `which`
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:@"/usr/bin/which"];
  [task setArguments:@[command]];

  NSPipe *pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];
  [task setStandardError:[NSPipe pipe]];

  @try
    {
      [task launch];
      [task waitUntilExit];
      BOOL exists = ([task terminationStatus] == 0);
      NSLog(@"OnDemand -> _commandExists: which %@ -> %s", command, exists ? "YES" : "NO");
      return exists;
    }
  @catch (NSException *e)
    {
      NSLog(@"OnDemand -> _commandExists: which %@ -> exception %@", command, e);
      return NO;
    }
}

/// Resolve a command to an absolute path. Returns nil on failure.
- (NSString *)_resolveCommandPath:(NSString *)command
{
  if ([command hasPrefix:@"/"])
    return command;

  id<GWSystemCommandExecutor> exec = [GWSystemCommandExecutor sharedExecutor];
  NSString *output = nil;
  int rc = [exec execute:@"/usr/bin/which" arguments:@[command] output:&output];
  if (rc == 0 && output)
    {
      NSString *path = [output stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([path length] > 0)
        return path;
    }
  return nil;
}

/// Exit codes used by OnDemand:
///   0 = success
///   1 = setup/plist error
///   2 = command not found / can't resolve path
///   3 = installation failed
///   4 = NSTask execution exception
///   otherwise = exit code from the launched command (passed through)

/// Execute a command via NSTask, inheriting stdio so stdout/stderr
/// and the exit code pass through to the caller.
/// Returns: command's exit code (>= 0), -2 if not found, -4 on exception.
- (int)_executeCommand:(NSString *)command arguments:(NSArray<NSString *> *)args
{
  if (!command || [command length] == 0)
    {
      NSLog(@"OnDemand -> _executeCommand: (empty) -> exit -1");
      return -1;
    }

  NSString *path = [self _resolveCommandPath:command];
  if (!path)
    {
      NSLog(@"OnDemand [FAIL] _executeCommand: '%@' not found in PATH", command);
      return -2;
    }

  NSLog(@"OnDemand -> _executeCommand: %@ %@", path,
        [args count] > 0 ? [args componentsJoinedByString:@" "] : @"");

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:path];
  if ([args count] > 0)
    [task setArguments:args];
  // Pass through the parent's environment so the launched app sees
  // the same PATH, DISPLAY, etc. as OnDemand
  [task setEnvironment:[[NSProcessInfo processInfo] environment]];
  // Do NOT set standardOutput/standardError — leaving them unset
  // makes the child inherit the parent's stdio so output and exit
  // codes pass through to the caller.

  @try
    {
      [task launch];
      [task waitUntilExit];
      int status = [task terminationStatus];
      NSLog(@"OnDemand <- _executeCommand: %@ -> exit %d", path, status);
      return status;
    }
  @catch (NSException *e)
    {
      NSLog(@"OnDemand [FAIL] _executeCommand: exception running %@: %@", path, e);
      return -4;
    }
}

/// Map _executeCommand return value to an exit code and call exit().
- (void)_exitWithCommandStatus:(int)status command:(NSString *)command
{
  int code;
  if (status >= 0)
    code = status;                                   // pass through command's exit code
  else if (status == -2)
    code = 2;                                        // command not found
  else if (status == -4)
    code = 4;                                        // NSTask exception
  else
    code = 1;                                        // unknown error

  NSLog(@"OnDemand -> _exitWithCommandStatus: %d -> exit(%d)", status, code);
  exit(code);
}

#pragma mark - Direct Launch (no GUI)

- (BOOL)commandIsAvailable
{
  NSString *command = [_spec postCommand];
  return command ? [self _commandExists:command] : NO;
}

- (BOOL)launchAndExit
{
  NSString *command = [_spec postCommand];
  NSArray *args = [_spec postCommandArguments];
  NSLog(@"OnDemand -> launchAndExit: %@ %@", command,
        [args count] > 0 ? [args componentsJoinedByString:@" "] : @"");
  int status = [self _executeCommand:command arguments:args];
  [self _exitWithCommandStatus:status command:command];
  return YES; // unreachable
}

#pragma mark - Main Workflow (install + launch)

/// Show an error and schedule clean termination (helper for the install path)
- (void)_showInstallError:(NSString *)message
{
  NSLog(@"OnDemand [FAIL] Download FAILED: %@", message);
  [self _showError:message];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (!_isTerminating)
      {
        _isTerminating = YES;
        [NSApp terminate:nil];
      }
  });
}

/// Post-install launch step — called on the main thread after a successful install.
- (void)_launchAfterInstall
{
  [_progressBar setDoubleValue:1.0];
  [_window setTitle:[NSString stringWithFormat:@"Downloading %@", _appName]];
  NSString *command = [_spec postCommand];
  NSArray *commandArgs = [_spec postCommandArguments];

  // Close the progress window before launching the app
  [_window orderOut:nil];

  if (command)
    {
      NSLog(@"OnDemand -> [Step 2/2] Executing command: %@", command);
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int status = [self _executeCommand:command arguments:commandArgs];
        NSLog(@"OnDemand [OK] [Step 2/2] Execution finished (status %d), exiting", status);
        exit(status >= 0 ? status : 1);
      });
    }
  else
    {
      NSLog(@"OnDemand -> performInstallAndLaunch: no postinstall command, done");
      exit(0);
    }
}

- (void)performInstallAndLaunch
{
  NSString *command = [_spec postCommand];
  NSArray *packages = [_spec packages];
  NSArray *localFiles = [_spec localFilePaths];

  NSLog(@"OnDemand -> performInstallAndLaunch: BEGIN (command=%@, packages=%@, local=%@)",
        command, packages, localFiles);
  [_statusField setStringValue:@"Downloading…"];

  // Run the blocking install on a background thread so the UI stays responsive
  // and the progress bar updates in real time
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSError *error = nil;
    BOOL success = [_pm installPackages:packages
                         localFilePaths:localFiles
                              progress:self
                                 error:&error];

    dispatch_async(dispatch_get_main_queue(), ^{
      if (!success)
        {
          NSString *captured = [_pm capturedErrorOutput];

          // ── Auto-recover from interrupted dpkg state ──
          if (!_dpkgRetried && captured &&
              [captured rangeOfString:@"dpkg --configure -a"].location != NSNotFound)
            {
              _dpkgRetried = YES;
              NSLog(@"OnDemand: dpkg was interrupted, running --configure -a and retrying...");
              [_statusField setStringValue:@"Recovering from interrupted package configuration…"];

              dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // Fix the interrupted dpkg state
                [self _executeCommand:@"/usr/bin/sudo"
                           arguments:@[@"dpkg", @"--configure", @"-a"]];

                // Retry the install once
                NSError *retryError = nil;
                BOOL retrySuccess = [_pm installPackages:packages
                                          localFilePaths:localFiles
                                               progress:self
                                                  error:&retryError];

                dispatch_async(dispatch_get_main_queue(), ^{
                  if (retrySuccess)
                    {
                      NSLog(@"OnDemand: dpkg recovery succeeded, continuing...");
                      [self _launchAfterInstall];
                    }
                  else
                    {
                      NSString *retryCaptured = [_pm capturedErrorOutput];
                      if ([retryCaptured hasPrefix:@"E: "])
                        retryCaptured = [retryCaptured substringFromIndex:3];
                      if ([retryCaptured length] == 0)
                        retryCaptured = [GWPackageManager friendlyErrorMessageForError:retryError
                                                                                appName:_appName];
                      [self _showInstallError:retryCaptured];
                    }
                });
              });
              return;
            }

          // ── Normal error ──
          if ([captured hasPrefix:@"E: "])
            captured = [captured substringFromIndex:3];
          NSString *msg = captured;
          if ([msg length] == 0)
            msg = [GWPackageManager friendlyErrorMessageForError:error
                                                          appName:_appName];
          [self _showInstallError:msg];
          return;
        }

      NSLog(@"OnDemand [OK] [Step 1/2] Download succeeded");
      [self _launchAfterInstall];
    });
  });
}

#pragma mark - Error Display

- (void)_showError:(NSString *)message
{
  NSLog(@"OnDemand: Error — %@", message);

  // Close the progress window before showing the error
  [_window orderOut:nil];

  // Show error in a standalone alert (avoids reusing same window views)
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:_appName ?: @"Application"];
  [alert setInformativeText:message];
  [alert addButtonWithTitle:@"Cancel"];
  [alert setAlertStyle:0]; // critical

  void (^showBlock)(void) = ^{
    [alert runModal];
    if (!_isTerminating)
      {
        _isTerminating = YES;
        [NSApp terminate:nil];
      }
  };

  if ([NSThread isMainThread])
    showBlock();
  else
    dispatch_sync(dispatch_get_main_queue(), showBlock);
}

- (void)quitClicked:(id)sender
{
  if (_isTerminating) return;
  _isTerminating = YES;
  [NSApp terminate:nil];
}

#pragma mark - Live Output from Backend

/// Parse a size suffix (MB, kB, B) from the given string and convert to bytes.
/// Assumes scanner has already scanned a double value at `rest`.
static double _sizeSuffixToBytes(NSString *rest, double val)
{
  if ([rest rangeOfString:@"MB"].location != NSNotFound ||
      [rest rangeOfString:@"MiB"].location != NSNotFound ||
      [rest rangeOfString:@"MB"].location != NSNotFound)
    return val * 1024.0 * 1024.0;
  if ([rest rangeOfString:@"kB"].location != NSNotFound ||
      [rest rangeOfString:@"KiB"].location != NSNotFound)
    return val * 1024.0;
  if ([rest rangeOfString:@"B"].location != NSNotFound)
    return val;
  return 0.0;
}

/// Try to parse "marker <number> <unit>" (unit after number).
static double _parseSizeAfter(NSString *line, NSString *marker)
{
  NSRange r = [line rangeOfString:marker];
  if (r.location == NSNotFound) return 0.0;
  NSString *rest = [line substringFromIndex:r.location + r.length];
  NSScanner *scanner = [NSScanner scannerWithString:rest];
  double val;
  if ([scanner scanDouble:&val])
    return _sizeSuffixToBytes(rest, val);
  return 0.0;
}

/// Try to parse "<number> <unit> marker" (unit before marker, e.g. "80 MB to be downloaded.").
static double _parseSizeBefore(NSString *line, NSString *marker)
{
  NSRange r = [line rangeOfString:marker];
  if (r.location == NSNotFound) return 0.0;
  NSString *before = [line substringToIndex:r.location];
  // Scan backwards: find the last number + unit before the marker
  NSScanner *scanner = [NSScanner scannerWithString:before];
  [scanner setCharactersToBeSkipped:nil];
  double val = 0.0;
  // Walk tokens from the end
  NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
  NSString *trimmed = [before stringByTrimmingCharactersInSet:ws];
  if ([trimmed length] == 0) return 0.0;
  // Split on whitespace, last two meaningful tokens should be number and unit
  NSArray *tokens = [trimmed componentsSeparatedByCharactersInSet:ws];
  tokens = [tokens filteredArrayUsingPredicate:
    [NSPredicate predicateWithFormat:@"length > 0"]];
  NSInteger count = [tokens count];
  if (count < 2) return 0.0;
  NSString *lastUnit = tokens[count - 1];
  NSString *lastNum  = tokens[count - 2];
  // Check that lastNum is actually a number
  NSScanner *numScan = [NSScanner scannerWithString:lastNum];
  if ([numScan scanDouble:&val])
    return _sizeSuffixToBytes(lastUnit, val);
  return 0.0;
}

- (void)installDidOutputLine:(NSString *)line
{
  if (!line) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (_logController)
      [_logController appendLog:[line stringByAppendingString:@"\n"]];

    // ═══════════════════════════════════════════════════════════
    // 1. Total download size (first match across all backends)
    // ═══════════════════════════════════════════════════════════
    if (_totalDownloadBytes == 0.0)
      {
        // apt:   "Need to get X MB/kB of archives"
        double sz = _parseSizeAfter(line, @"Need to get ");
        if (sz == 0.0)
          // pacman: "Total Download Size:  X.XX MB"
          sz = _parseSizeAfter(line, @"Total Download Size: ");
        if (sz == 0.0)
          // pkg:   "X MB/kB to be downloaded."
          sz = _parseSizeBefore(line, @" to be downloaded.");
        if (sz > 0.0)
          _totalDownloadBytes = sz;
      }

    // ═══════════════════════════════════════════════════════════
    // 2. Download-phase progress
    // ═══════════════════════════════════════════════════════════

    // 2a. apt: parse "Get:N ... [X MB/kB]" → _downloadedBytes
    if (_totalDownloadBytes > 0.0)
      {
        NSRange r = [line rangeOfString:@"["];
        if (r.location != NSNotFound)
          {
            NSString *rest = [line substringFromIndex:r.location + 1];
            NSRange end = [rest rangeOfString:@"]"];
            if (end.location != NSNotFound)
              {
                NSString *sizeStr = [rest substringToIndex:end.location];
                NSScanner *scanner = [NSScanner scannerWithString:sizeStr];
                double val;
                if ([scanner scanDouble:&val])
                  {
                    double bytes = _sizeSuffixToBytes(sizeStr, val);
                    if (bytes > 0.0)
                      {
                        _downloadedBytes += bytes;
                        CGFloat p = MIN(_downloadedBytes / _totalDownloadBytes, 1.0);
                        [_progressBar setIndeterminate:NO];
                        [_progressBar setDoubleValue:0.05 + p * 0.7];
                        [_progressBar displayIfNeeded];
                      }
                  }
              }
          }
      }

    // 2b. pacman 6+: total progress bar "Total ( n/m)  ... [####] XX%"
    {
      NSRange r = [line rangeOfString:@"Total ("];
      if (r.location != NSNotFound)
        {
          // Find the last "%" in the line
          NSRange pct = [line rangeOfString:@"%" options:NSBackwardsSearch];
          if (pct.location != NSNotFound && pct.location > 2)
            {
              NSUInteger start = pct.location;
              while (start > 0 && isdigit([line characterAtIndex:start - 1]))
                start--;
              if (start < pct.location)
                {
                  CGFloat p = [[line substringWithRange:
                    NSMakeRange(start, pct.location - start)] floatValue] / 100.0;
                  if (p >= 0.0 && p <= 1.0)
                    {
                      [_progressBar setIndeterminate:NO];
                      [_progressBar setDoubleValue:0.05 + p * 0.7];
                      [_progressBar displayIfNeeded];
                    }
                }
            }
        }
    }

    // 2c. FreeBSD pkg: "Fetching <pkg>: XX%" — track each file's completion
    {
      NSString *fetchPrefix = @"Fetching ";
      if ([line hasPrefix:fetchPrefix])
        {
          NSRange pct = [line rangeOfString:@"%" options:NSBackwardsSearch];
          if (pct.location != NSNotFound && pct.location > 2)
            {
              NSUInteger start = pct.location;
              while (start > 0 && isdigit([line characterAtIndex:start - 1]))
                start--;
              if (start < pct.location)
                {
                  CGFloat filePct = [[line substringWithRange:
                    NSMakeRange(start, pct.location - start)] floatValue] / 100.0;
                  // When percentage drops, a new file started
                  if (_lastFetchPct >= 0.99 && filePct < 0.1)
                    _completedFetchFiles++;
                  _lastFetchPct = filePct;
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 3. Install-phase progress  (dpkg, pacman, pkg)
    // ═══════════════════════════════════════════════════════════

    // 3a. dpkg: "(Reading database ... 45%)"
    {
      NSRange r = [line rangeOfString:@"%"];
      if (r.location != NSNotFound && r.location > 0)
        {
          NSUInteger start = r.location;
          while (start > 0 && isdigit([line characterAtIndex:start - 1]))
            start--;
          if (start < r.location)
            {
              CGFloat pct = [[line substringWithRange:
                NSMakeRange(start, r.location - start)] floatValue] / 100.0;
              if (pct >= 0.0 && pct <= 1.0)
                {
                  [_progressBar setIndeterminate:NO];
                  [_progressBar setDoubleValue:0.75 + pct * 0.25];
                  [_progressBar displayIfNeeded];
                }
            }
        }
    }

    // 3b. pacman install: "(n/m) installing/checking..." and
    //     pkg install:     "[n/m] Installing/Extracting..."
    {
      // Try parentheses first: pacman "(n/m)"
      NSRange open = [line rangeOfString:@"("];
      NSRange close = [line rangeOfString:@")"];
      if (open.location != NSNotFound && close.location != NSNotFound &&
          close.location > open.location)
        {
          NSString *inner = [line substringWithRange:
            NSMakeRange(open.location + 1,
                        close.location - open.location - 1)];
          NSArray *parts = [inner componentsSeparatedByString:@"/"];
          if ([parts count] == 2)
            {
            CGFloat n = [parts[0] floatValue];
            CGFloat m = [parts[1] floatValue];
            if (n >= 1.0 && m >= n)
              {
                [_progressBar setIndeterminate:NO];
                [_progressBar setDoubleValue:0.75 + (n / m) * 0.25];
                [_progressBar displayIfNeeded];
              }
            }
        }

      // Try brackets: pkg "[n/m]"
      NSRange ob = [line rangeOfString:@"["];
      NSRange cb = [line rangeOfString:@"]"];
      if (ob.location != NSNotFound && cb.location != NSNotFound &&
          cb.location > ob.location)
        {
          NSString *inner = [line substringWithRange:
            NSMakeRange(ob.location + 1,
                        cb.location - ob.location - 1)];
          NSArray *parts = [inner componentsSeparatedByString:@"/"];
          if ([parts count] == 2)
            {
            CGFloat n = [parts[0] floatValue];
            CGFloat m = [parts[1] floatValue];
            if (n >= 1.0 && m >= n)
              {
                [_progressBar setIndeterminate:NO];
                [_progressBar setDoubleValue:0.75 + (n / m) * 0.25];
                [_progressBar displayIfNeeded];
              }
            }
        }

      // OpenBSD pkg_add -V: line containing "n/m" (bare fraction)
      {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *toks = [trimmed componentsSeparatedByCharactersInSet:
          [NSCharacterSet characterSetWithCharactersInString:@" :"]];
        for (NSString *tok in toks)
          {
            NSArray *parts = [tok componentsSeparatedByString:@"/"];
            if ([parts count] == 2)
              {
                CGFloat n = [parts[0] floatValue];
                CGFloat m = [parts[1] floatValue];
                if (n >= 1.0 && m >= n && m <= 999)
                  {
                    [_progressBar setIndeterminate:NO];
                    [_progressBar setDoubleValue:0.75 + (n / m) * 0.25];
                    [_progressBar displayIfNeeded];
                  }
              }
          }
      }
    }
  });
}

#pragma mark - Installer Log

- (void)showLog:(id)sender
{
  if (!_logController) return;
  [[_logController window] makeKeyAndOrderFront:nil];
}

#pragma mark - About Dialog

- (void)showAbout:(id)sender
{
  [NSApp orderFrontStandardAboutPanel:sender];
}

#pragma mark - NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
  NSLog(@"OnDemand -> applicationDidFinishLaunching: showing download dialog");

  // Create log window controller
  _logController = [[ODLogWindowController alloc] init];

  // ── Set up main menu ──
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

  /* Application Menu */
  NSString *appName = [[NSProcessInfo processInfo] processName];
  NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:appName
                                                       action:nil
                                                keyEquivalent:@""];
  [mainMenu addItem:appMenuItem];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
  [appMenu addItemWithTitle:@"About"
                     action:@selector(showAbout:)
              keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit"
                     action:@selector(terminate:)
              keyEquivalent:@"q"];
  [appMenuItem setSubmenu:appMenu];

  /* Edit Menu */
  NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit"
                                                        action:nil
                                                 keyEquivalent:@""];
  [mainMenu addItem:editMenuItem];
  NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
  [editMenu addItem:[NSMenuItem separatorItem]];
  [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  [editMenuItem setSubmenu:editMenu];

  /* Window Menu */
  NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window"
                                                          action:nil
                                                   keyEquivalent:@""];
  [mainMenu addItem:windowMenuItem];
  NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  [windowMenu addItemWithTitle:@"Minimize"
                        action:@selector(performMiniaturize:)
                 keyEquivalent:@"m"];
  [windowMenu addItemWithTitle:@"Zoom"
                        action:@selector(performZoom:)
                 keyEquivalent:@""];
  [windowMenu addItem:[NSMenuItem separatorItem]];
  [windowMenu addItemWithTitle:@"Installer Log"
                        action:@selector(showLog:)
                 keyEquivalent:@"l"];
  [windowMenu addItem:[NSMenuItem separatorItem]];
  [windowMenu addItemWithTitle:@"Bring All to Front"
                        action:@selector(arrangeInFront:)
                 keyEquivalent:@""];
  [windowMenuItem setSubmenu:windowMenu];
  [NSApp setWindowsMenu:windowMenu];

  [NSApp setMainMenu:mainMenu];

  if (_isDirectInstall)
    {
      /* Direct install: ask for confirmation first, only then show progress */
      [self performDirectInstall];
    }
  else
    {
      [self showWindow];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
  return YES;
}

@end
