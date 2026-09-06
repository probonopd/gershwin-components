/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "BuildApplication.h"
#import "BuildController.h"
#import "CatalogEntry.h"
#import "GWBuildPreflight.h"

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

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        // Process command line arguments
        // Use -makefilePath flag so NSApp doesn't treat it as a file to open
        NSArray *args = [[NSProcessInfo processInfo] arguments];
        NSString *makefilePath = nil;
        NSString *catalogBuildName = nil;
        NSMutableArray *extraArgs = [NSMutableArray array];
        BOOL noGui = NO;
        BOOL autoInstallLaunch = NO;
        BOOL keepBuildDir = NO;
        BOOL nextIsMakefile = NO;
        BOOL nextIsCatalog = NO;
        for (NSUInteger i = 1; i < [args count]; i++) {
            NSString *arg = [args objectAtIndex: i];
            if ([arg isEqualToString: @"-makefilePath"]) {
                nextIsMakefile = YES;
            } else if ([arg isEqualToString: @"-GSFilePath"]) {
                nextIsMakefile = YES;
            } else if ([arg isEqualToString: @"-catalogBuildName"]) {
                nextIsCatalog = YES;
            } else if ([arg isEqualToString: @"-autoInstallLaunch"]) {
                autoInstallLaunch = YES;
            } else if ([arg isEqualToString: @"-keepBuildDir"]) {
                keepBuildDir = YES;
            } else if ([arg isEqualToString: @"-noGui"]) {
                noGui = YES;
            } else if ([arg isEqualToString: @"-h"] || [arg isEqualToString: @"-help"]) {
                fprintf(stdout, "Usage: %s [-makefilePath <GNUmakefile>] [-catalogBuildName <name>] [-noGui] [-autoInstallLaunch] [-keepBuildDir] [extra gmake args...]\n"
                                "\n"
                                "Options:\n"
                                "  -makefilePath <path>    Path to the GNUmakefile to build\n"
                                "  -catalogBuildName <name> Build an app from the catalog by name\n"
                                "  -noGui                  Force console mode (no progress window)\n"
                                "  -autoInstallLaunch      Automatically install and launch on success\n"
                                "  -keepBuildDir           Keep temporary build directory after success\n"
                                "  -h, -help              Show this help message\n"
                                "\n"
                                "The build always runs 'make clean' first.\n"
                                "In GUI mode, use the file dialog if no path is given.\n",
                        [[args objectAtIndex: 0] UTF8String]);
                exit(0);
            } else if (nextIsMakefile) {
                makefilePath = arg;
                nextIsMakefile = NO;
            } else if (nextIsCatalog) {
                catalogBuildName = arg;
                nextIsCatalog = NO;
            } else {
                [extraArgs addObject: arg];
            }
        }

        BOOL hasDisplay = (getenv("DISPLAY") != NULL) && !noGui;

        if (!hasDisplay) {
            // Console mode, run build directly without GUI
            NSString *catalogCloneDir = nil;
            if (catalogBuildName) {
                // Catalog build mode: find entry, clone, and build
                NSArray *entries = [CatalogEntry loadCatalog];
                CatalogEntry *entry = nil;
                for (CatalogEntry *e in entries) {
                    if ([[e.name lowercaseString] isEqualToString:[catalogBuildName lowercaseString]]) {
                        entry = e;
                        break;
                    }
                }
                if (!entry) {
                    fprintf(stderr, "Error: catalog entry '%s' not found.\n", [catalogBuildName UTF8String]);
                    fprintf(stderr, "Available entries:");
                    for (CatalogEntry *e in entries) {
                        fprintf(stderr, " %s", [e.name UTF8String]);
                    }
                    fprintf(stderr, "\n");
                    exit(1);
                }

                NSString *template = [NSString stringWithFormat:@"/tmp/Build-catalog-%@-XXXXXXXX",
                                      [entry.name stringByReplacingOccurrencesOfString:@" " withString:@"_"]];
                char *tmpPath = strdup([template UTF8String]);
                if (!mkdtemp(tmpPath)) {
                    fprintf(stderr, "Error: could not create temporary directory.\n");
                    exit(1);
                }
                NSString *cloneDir = [[NSString stringWithUTF8String:tmpPath] stringByStandardizingPath];
                free(tmpPath);
                catalogCloneDir = cloneDir;

                fprintf(stderr, "Cloning %s...\n", [entry.gitURL UTF8String]);
                NSTask *gitTask = [[NSTask alloc] init];
                [gitTask setLaunchPath:toolPath(@"git")];
                [gitTask setArguments:@[@"clone", @"--depth=1", entry.gitURL, cloneDir]];
                [gitTask setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
                [gitTask setStandardError:[NSFileHandle fileHandleWithNullDevice]];
                @try {
                    [gitTask launch];
                    [gitTask waitUntilExit];
                } @catch (NSException *e) {
                    fprintf(stderr, "Error: git clone failed: %s\n", [[e reason] UTF8String]);
                    exit(1);
                }
                if ([gitTask terminationStatus] != 0) {
                    fprintf(stderr, "Error: git clone returned status %d.\n", [gitTask terminationStatus]);
                    exit(1);
                }

                NSFileManager *fm = [NSFileManager defaultManager];
                if (entry.makefilePath) {
                    NSString *mf = [cloneDir stringByAppendingPathComponent:entry.makefilePath];
                    if ([fm fileExistsAtPath:mf]) {
                        makefilePath = mf;
                    }
                }
                if (!makefilePath) {
                    for (NSString *name in @[@"GNUmakefile", @"GNUmakefile.in", @"Makefile"]) {
                        NSString *mf = [cloneDir stringByAppendingPathComponent:name];
                        if ([fm fileExistsAtPath:mf]) {
                            makefilePath = mf;
                            break;
                        }
                    }
                }
                if (!makefilePath) {
                    fprintf(stderr, "Error: no GNUmakefile or Makefile found in cloned repository.\n");
                    exit(1);
                }
                fprintf(stderr, "Found makefile: %s\n", [makefilePath UTF8String]);

                // Fall through to the makefilePath build logic below
            }

            if (makefilePath) {
                NSString *dir = [makefilePath stringByDeletingLastPathComponent];
                if ([dir length] == 0) dir = @".";
                NSString *makePath = toolPath(@"gmake");
                if (!makePath) makePath = toolPath(@"make");

                // Run pre-build steps (autoreconf, configure)
                NSFileManager *fm = [NSFileManager defaultManager];
                NSString *configureAc = [dir stringByAppendingPathComponent: @"configure.ac"];
                NSString *configureIn = [dir stringByAppendingPathComponent: @"configure.in"];
                NSString *configure = [dir stringByAppendingPathComponent: @"configure"];
                NSString *makefileIn = [dir stringByAppendingPathComponent: @"GNUmakefile.in"];

                if ([fm fileExistsAtPath: configureAc] || [fm fileExistsAtPath: configureIn]) {
                    NSString *src = [fm fileExistsAtPath: configureAc] ? configureAc : configureIn;
                    BOOL needsAutoreconf = NO;
                    if (![fm fileExistsAtPath: configure]) {
                        needsAutoreconf = YES;
                    } else {
                        NSDictionary *sAttr = [fm attributesOfItemAtPath: src error: NULL];
                        NSDictionary *cAttr = [fm attributesOfItemAtPath: configure error: NULL];
                        if (sAttr && cAttr && [[sAttr fileModificationDate] laterDate: [cAttr fileModificationDate]] == [sAttr fileModificationDate])
                            needsAutoreconf = YES;
                    }
                    if (needsAutoreconf) {
                        NSString *ar = toolPath(@"autoreconf");
                        if (ar) {
                            fprintf(stderr, "Running autoreconf -i in %s\n", [dir UTF8String]);
                            system([[NSString stringWithFormat: @"cd '%@' && autoreconf -i 2>&1", dir] UTF8String]);
                        }
                    }
                }

                if ([fm fileExistsAtPath: makefileIn]) {
                    NSString *makefileLocal = [dir stringByAppendingPathComponent: @"GNUmakefile"];
                    BOOL needsConfigure = ![fm fileExistsAtPath: makefileLocal];
                    if (!needsConfigure) {
                        NSDictionary *inAttr = [fm attributesOfItemAtPath: makefileIn error: NULL];
                        NSDictionary *mkAttr = [fm attributesOfItemAtPath: makefileLocal error: NULL];
                        if (inAttr && mkAttr && [[inAttr fileModificationDate] laterDate: [mkAttr fileModificationDate]] == [inAttr fileModificationDate])
                            needsConfigure = YES;
                    }
                    if (needsConfigure) {
                        if ([fm isExecutableFileAtPath: configure]) {
                            fprintf(stderr, "Running ./configure in %s\n", [dir UTF8String]);
                            system([[NSString stringWithFormat: @"cd '%@' && ./configure 2>&1", dir] UTF8String]);
                        } else if ([fm fileExistsAtPath: configure]) {
                            fprintf(stderr, "Running sh configure in %s\n", [dir UTF8String]);
                            system([[NSString stringWithFormat: @"cd '%@' && sh configure 2>&1", dir] UTF8String]);
                        }
                    }
                }

                if (!makePath) {
                    fprintf(stderr, "Error: neither gmake nor make found in PATH\n");
                    exit(1);
                }

                // Package preflight: scan sources for missing system headers
                // and install the providing packages (with a y/N prompt).
                {
                    NSString *scanRoot = (catalogCloneDir != nil) ? catalogCloneDir : dir;
                    GWBuildPreflight *preflight = [[GWBuildPreflight alloc]
                        initWithSourceRoot:scanRoot makefilePath:makefilePath];
                    [preflight setConsoleMode:YES];
                    NSString *blacklistPath = [[NSBundle mainBundle] pathForResource:@"Blacklist" ofType:@"plist"];
                    NSArray *blacklist = blacklistPath ? [NSArray arrayWithContentsOfFile:blacklistPath] : @[];
                    [preflight setBlacklist:blacklist];
                    NSError *preflightError = nil;
                    GWPreflightDecision decision = [preflight runWithProgress:nil
                                                                      output:^(NSString *line) {
                        fprintf(stderr, "%s\n", [line UTF8String]);
                    } error:&preflightError];
                    if (decision == GWPreflightDecisionAbort) {
                        fprintf(stderr, "Preflight aborted: %s\n",
                                [([preflightError localizedDescription] ?: @"cancelled by user") UTF8String]);
                        exit(1);
                    }
                    // If packages were installed, re-run configure: the run
                    // above happened before the packages were present and may
                    // have missed headers / tools they now provide.
                    if ([preflight installedPackages] && [fm fileExistsAtPath: configure]) {
                        fprintf(stderr, "Re-running configure after package installation in %s\n",
                                [dir UTF8String]);
                        if ([fm isExecutableFileAtPath: configure]) {
                            system([[NSString stringWithFormat: @"cd '%@' && ./configure 2>&1", dir] UTF8String]);
                        } else {
                            system([[NSString stringWithFormat: @"cd '%@' && sh configure 2>&1", dir] UTF8String]);
                        }
                    }
                }

                NSTask *task = [[NSTask alloc] init];
                [task setCurrentDirectoryPath: dir];
                [task setLaunchPath: makePath];
                NSMutableArray *taskArgs = [NSMutableArray arrayWithObjects: @"-f", makefilePath, @"clean", nil];
                [taskArgs addObjectsFromArray: extraArgs];
                [taskArgs addObject: @"all"];
                [task setArguments: taskArgs];
                [task setEnvironment: [[NSProcessInfo processInfo] environment]];
                NSPipe *pipe = [[NSPipe alloc] init];
                [task setStandardOutput: pipe];
                [task setStandardError: pipe];
                NSFileHandle *handle = [pipe fileHandleForReading];
                [task launch];
                while (1) {
                    NSData *data = [handle availableData];
                    if (data.length == 0) {
                        if ([task isRunning]) {
                            [NSThread sleepForTimeInterval: 0.1];
                        } else {
                            break;
                        }
                    } else {
                        NSString *str = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
                        write(STDERR_FILENO, [str UTF8String], [str length]);
                    }
                }
                exit([task terminationStatus]);
            } else {
                fprintf(stderr, "Usage: %s -makefilePath <GNUmakefile> [extra gmake args...]\n"
                                "   or: %s -catalogBuildName <name> [extra gmake args...]\n"
                                "   or: %s [-noGui] -catalogBuildName <name> [extra gmake args...]\n",
                        [[args objectAtIndex: 0] UTF8String],
                        [[args objectAtIndex: 0] UTF8String],
                        [[args objectAtIndex: 0] UTF8String]);
                exit(1);
            }
        } else {
            // GUI mode
            BuildApplication *app = (BuildApplication *)[BuildApplication sharedApplication];
            [app setDelegate: app];
            [(BuildApplication *)app setMakefilePath: makefilePath];
            [(BuildApplication *)app setExtraArgs: extraArgs];
            [(BuildApplication *)app setCatalogBuildName: catalogBuildName];
            [(BuildApplication *)app setAutoInstallLaunch: autoInstallLaunch];
            [(BuildApplication *)app setKeepBuildDir: keepBuildDir];
            [app finishLaunching];
            [app startBuildWorkflow];
            [app run];
        }
        return 0;
    }
}