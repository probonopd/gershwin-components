/*
 * Copyright 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class BWLogWindowController;

@interface BWLogWindowController : NSWindowController
- (void)appendLog:(NSString *)text;
@end

@interface BuildController : NSObject <NSWindowDelegate>
{
    NSWindow *_window;
    NSTextField *_statusField;
    NSProgressIndicator *_progressBar;
    NSButton *_cancelButton;

    NSTask *buildTask;
    NSPipe *outputPipe;
    NSString *makefilePath;
    NSTask *installTask;
    NSPipe *installPipe;
    BOOL installShouldLaunch;
    BWLogWindowController *_logController;
    NSImageView *_iconView;
    NSTextField *_nameField;
    NSMutableArray *_projectFileCounts;
    NSMutableArray *_projectCompiledCounts;
    NSInteger _currentProjectIndex;
    NSString *_objDir;
    BOOL _dependencyResolved;
    NSInteger _closeCount;
    NSTimer *_closeTimer;
}

@property (strong) NSString *makefilePath;
@property (strong) NSMutableString *buildOutput;
@property BOOL consoleMode;
@property BOOL autoInstallLaunch;
@property BOOL keepBuildDir;
@property (strong) NSString *buildDir;
@property (strong) NSArray *extraArgs;
@property NSInteger closeCount;
@property (strong) NSTimer *closeTimer;

@property (readonly) BWLogWindowController *logController;

dispatch_queue_t buildQueue(void);

- (void)showWindow;
- (void)showProgressWindow;
- (void)hideProgressWindow;
- (void)reloadIcon;
- (void)startBuild;
- (void)showLog:(id)sender;

@end
