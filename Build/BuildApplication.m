/*
 * Copyright 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BuildApplication.h"
#import "BuildController.h"
#import "CatalogController.h"
#import "CatalogEntry.h"

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

@implementation BuildApplication

- (id)init
{
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillTerminate:)
                                                     name:NSApplicationWillTerminateNotification
                                                   object:nil];
    }
    return self;
}

@synthesize makefilePath;
@synthesize extraArgs;
@synthesize catalogBuildName;
@synthesize autoInstallLaunch;
@synthesize keepBuildDir;
@synthesize currentController = _currentController;

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender
{
    return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"BuildApplication: willTerminate (reason=%@)", [notification userInfo]);
}

- (BOOL)isMakefileName:(NSString *)name
{
    return [name isEqualToString:@"GNUmakefile"]
        || [name isEqualToString:@"GNUmakefile.in"]
        || [name isEqualToString:@"Makefile"]
        || [name isEqualToString:@"makefile"];
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename
{
    NSString *name = [filename lastPathComponent];
    if (![self isMakefileName:name]) {
        return NO;
    }
    self.makefilePath = filename;
    self.extraArgs = @[];
    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames
{
    for (NSString *filename in filenames) {
        NSString *name = [filename lastPathComponent];
        if ([self isMakefileName:name]) {
            self.makefilePath = filename;
            self.extraArgs = @[];
            return;
        }
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    /* Build's main menu must be present for every launch path (the catalog
     * window and the makefile workflow alike); the catalog path never created
     * a BuildController before showing its window, so without this the app
     * ran with no menu bar. */
    [BuildController setupMainMenu];
}

- (void)startBuildWorkflow
{
    if (self.catalogBuildName) {
        [self buildCatalogAppWithName:self.catalogBuildName];
    } else if (self.makefilePath) {
        BuildController *controller = [[BuildController alloc] init];
        [controller setMakefilePath:self.makefilePath];
        [controller setExtraArgs:self.extraArgs];
        [controller setAutoInstallLaunch:self.autoInstallLaunch];
        [controller setKeepBuildDir:self.keepBuildDir];
        self.currentController = controller;
        [controller showWindow];
    } else {
        CatalogController *catalog = [[CatalogController alloc] init];
        self.currentController = catalog;
        [catalog showWindow];
    }
}

- (void)buildCatalogAppWithName:(NSString *)name
{
    NSArray *entries = [CatalogEntry loadCatalog];
    CatalogEntry *entry = nil;
    for (CatalogEntry *e in entries) {
        if ([[e.name lowercaseString] isEqualToString:[name lowercaseString]]) {
            entry = e;
            break;
        }
    }
    if (!entry) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Catalog Entry Not Found", @"Alert title: catalog entry missing")];
        [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"No catalog entry named '%@'.", @"Alert: no entry with name"), name]];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
        [alert runModal];
        return;
    }

    NSString *template = [NSString stringWithFormat:@"/tmp/Build-catalog-%@-XXXXXXXX",
                          [entry.name stringByReplacingOccurrencesOfString:@" " withString:@"_"]];
    char *tmpPath = strdup([template UTF8String]);
    if (!mkdtemp(tmpPath)) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Clone Failed", @"Alert title: clone failed")];
        [alert setInformativeText:NSLocalizedString(@"Could not create temporary directory.", @"Alert: temp dir error")];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
        [alert runModal];
        free(tmpPath);
        return;
    }
    NSString *cloneDir = [[NSString stringWithUTF8String:tmpPath] stringByStandardizingPath];
    free(tmpPath);

    NSString *guessedMakefile = [cloneDir stringByAppendingPathComponent:@"GNUmakefile"];

    BuildController *controller = [[BuildController alloc] init];
    [controller setMakefilePath:guessedMakefile];
    [controller setExtraArgs:self.extraArgs ? self.extraArgs : @[]];
    [controller setAutoInstallLaunch:self.autoInstallLaunch];
    [controller setKeepBuildDir:self.keepBuildDir];
    [controller setBuildDir:cloneDir];
    self.currentController = controller;
    [controller showProgressWindow];
    [NSApp updateWindows];

    /* Clone the repository on a background queue to keep GUI responsive */
    dispatch_async(buildQueue(), ^{
        NSTask *gitTask = [[NSTask alloc] init];
        [gitTask setLaunchPath:toolPath(@"git")];
        [gitTask setArguments:@[@"clone", @"--depth=1", entry.gitURL, cloneDir]];
        [gitTask setEnvironment:[[NSProcessInfo processInfo] environment]];

    NSPipe *gitPipe = [[NSPipe alloc] init];
    [gitTask setStandardOutput:gitPipe];
    [gitTask setStandardError:gitPipe];
    [gitTask setStandardInput:[NSFileHandle fileHandleWithNullDevice]];

        NSString *logMsg = [NSString stringWithFormat:NSLocalizedString(@"=== Cloning %@ ===\n", @"Log: cloning repo"), entry.gitURL];
        [controller.buildOutput appendString:logMsg];
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller.logController appendLog:logMsg];
        });
        write(STDOUT_FILENO, [logMsg UTF8String], [logMsg length]);

        BOOL cloneOK = YES;
        @try {
            [gitTask launch];

            NSFileHandle *handle = [gitPipe fileHandleForReading];
            while ([gitTask isRunning]) {
                NSData *data = [handle availableData];
                if ([data length] > 0) {
                    NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    [controller.buildOutput appendString:outStr];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [controller.logController appendLog:outStr];
                    });
                    write(STDOUT_FILENO, [data bytes], [data length]);
                }
            }
            NSData *remaining = [handle readDataToEndOfFile];
            if ([remaining length] > 0) {
                NSString *outStr = [[NSString alloc] initWithData:remaining encoding:NSUTF8StringEncoding];
                [controller.buildOutput appendString:outStr];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [controller.logController appendLog:outStr];
                });
                write(STDOUT_FILENO, [remaining bytes], [remaining length]);
            }
        } @catch (NSException *e) {
            cloneOK = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                [controller hideProgressWindow];
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:NSLocalizedString(@"Clone Failed", @"Alert title: clone failed")];
                [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"git clone failed: %@", @"Alert: git clone error with reason"), [e reason]]];
                [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                [alert runModal];
                [BuildController scheduleQuit];
            });
        }

        if (cloneOK && [gitTask terminationStatus] != 0) {
            cloneOK = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                [controller hideProgressWindow];
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:NSLocalizedString(@"Clone Failed", @"Alert title: clone failed")];
                [alert setInformativeText:NSLocalizedString(@"git clone returned an error.", @"Alert: git clone error")];
                [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                [alert runModal];
                [BuildController scheduleQuit];
            });
        }

        if (cloneOK) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *resolvedMakefile = nil;

            if (entry.makefilePath) {
                NSString *mf = [cloneDir stringByAppendingPathComponent:entry.makefilePath];
                if ([fm fileExistsAtPath:mf]) {
                    resolvedMakefile = mf;
                }
            }

            if (!resolvedMakefile) {
                for (NSString *mfName in @[@"GNUmakefile", @"GNUmakefile.in", @"Makefile"]) {
                    NSString *mf = [cloneDir stringByAppendingPathComponent:mfName];
                    if ([fm fileExistsAtPath:mf]) {
                        resolvedMakefile = mf;
                        break;
                    }
                }
            }

            if (!resolvedMakefile) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [controller hideProgressWindow];
                    NSAlert *alert = [[NSAlert alloc] init];
                    [alert setMessageText:NSLocalizedString(@"No Makefile Found", @"Alert title: no makefile")];
                    [alert setInformativeText:NSLocalizedString(@"The cloned repository does not contain a GNUmakefile or Makefile.", @"Alert: no makefile in clone")];
                    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                    [alert runModal];
                    [BuildController scheduleQuit];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [controller setMakefilePath:resolvedMakefile];
                    [controller reloadIcon];
                    [controller startBuild];
                });
            }
        }
    });
}

@end