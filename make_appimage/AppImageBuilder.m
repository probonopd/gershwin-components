/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AppImageBuilder.h"
#import "LibraryResolver.h"
#import "InterpreterDeployer.h"
#import "LibraryDeployer.h"

@interface AppImageBuilder ()
{
    BOOL _standalone;
    BOOL _verbose;
    NSString *_appResourcesDir;
}

- (NSString *)_runTool:(NSString *)tool withArgs:(NSArray *)args;
- (BOOL)_runTool:(NSString *)tool withArgs:(NSArray *)args error:(NSError **)error;
- (NSString *)_findTool:(NSString *)name;

@end

@implementation AppImageBuilder

- (instancetype)initWithAppName:(NSString *)name
{
    self = [super init];
    if (self) {
        _appName = [name copy];
        _appimageTool = @"appimagetool";
        _buildDir = [NSString stringWithFormat:@"/tmp/appimage-%@", name];
        _appDirPath = [_buildDir stringByAppendingPathComponent:@"AppDir"];
        _allELFs = [NSMutableArray array];
        _seenDeps = [NSMutableArray array];
        _libraryLocations = [NSMutableArray array];
        _standalone = YES;
    }
    return self;
}

- (void)setOutputFile:(NSString *)path       { _outputFile = [path copy]; }
- (void)setBuildDirectory:(NSString *)dir    { _buildDir = [dir copy]; _appDirPath = [_buildDir stringByAppendingPathComponent:@"AppDir"]; }
- (void)setComment:(NSString *)comment        { _comment = [comment copy]; }
- (void)setCategories:(NSString *)categories  { _categories = [categories copy]; }
- (void)setMainExecutable:(NSString *)path   { _mainExec = [path copy]; }
- (void)setAppimageTool:(NSString *)path      { _appimageTool = [path copy]; }
- (void)setStandalone:(BOOL)flag              { _standalone = flag; }
- (void)setVerbose:(BOOL)flag                 { _verbose = flag; }

#pragma mark - Tool path lookup

- (NSString *)_findTool:(NSString *)name
{
    if ([name isAbsolutePath]) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:name])
            return name;
        return nil;
    }
    NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    for (NSString *dir in [pathEnv componentsSeparatedByString:@":"]) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:full])
            return full;
    }
    return nil;
}

#pragma mark - Helper methods

- (NSString *)_runTool:(NSString *)tool withArgs:(NSArray *)args
{
    @try {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:tool];
        [task setArguments:args];

        NSPipe *outPipe = [NSPipe pipe];
        [task setStandardOutput:outPipe];
        [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

        [task launch];
        [task waitUntilExit];

        if ([task terminationStatus] != 0) return nil;

        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        NSString *result = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
        return [result stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } @catch (NSException *exception) {
        return nil;
    }
}

- (BOOL)_runTool:(NSString *)tool withArgs:(NSArray *)args error:(NSError **)error
{
    @try {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:tool];
        [task setArguments:args];

        NSPipe *outPipe = [NSPipe pipe];
        NSPipe *errPipe = [NSPipe pipe];
        [task setStandardOutput:outPipe];
        [task setStandardError:errPipe];

        [task launch];
        [task waitUntilExit];

        if ([task terminationStatus] != 0) {
            if (error) {
                NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
                NSString *errStr = [[NSString alloc] initWithData:errData
                                                         encoding:NSUTF8StringEncoding];
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                            code:[task terminationStatus]
                                        userInfo:@{NSLocalizedDescriptionKey: errStr ?: @"Command failed"}];
            }
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppImageBuilder"
                                        code:-1
                                    userInfo:@{NSLocalizedDescriptionKey: [exception reason]}];
        }
        return NO;
    }
}

#pragma mark - Build

- (BOOL)build
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *makePath = [self _findTool:@"make"];
    NSString *chmodPath = [self _findTool:@"chmod"];
    NSString *patchelfPath = [self _findTool:@"patchelf"];
    NSString *gnustepConfigPath = [self _findTool:@"gnustep-config"];

    // === (a) Find the application source/bundle ===
    NSLog(@"make_appimage: building %@", _appName);
    BOOL isPrebuiltBundle = NO;
    {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:_appName isDirectory:&isDir] && isDir) {
            _appDir = _appName;
            if ([[_appName pathExtension] isEqualToString:@"app"]) {
                NSString *makefile = [_appDir stringByAppendingPathComponent:@"GNUmakefile"];
                if ([fm fileExistsAtPath:makefile]) {
                    isPrebuiltBundle = NO;
                } else {
                    isPrebuiltBundle = YES;
                }
            } else {
                isPrebuiltBundle = NO;
            }
        } else {
            NSString *appBundle = [_appName stringByAppendingPathExtension:@"app"];
            if ([fm fileExistsAtPath:appBundle isDirectory:&isDir] && isDir) {
                _appDir = appBundle;
                NSString *makefile = [_appDir stringByAppendingPathComponent:@"GNUmakefile"];
                if ([fm fileExistsAtPath:makefile]) {
                    isPrebuiltBundle = NO;
                } else {
                    isPrebuiltBundle = YES;
                }
            } else {
                _appDir = _appName;
                isPrebuiltBundle = NO;
            }
        }

        if (!isPrebuiltBundle) {
            NSString *makefile = [_appDir stringByAppendingPathComponent:@"GNUmakefile"];
            if (![fm fileExistsAtPath:makefile]) {
                NSLog(@"make_appimage: No GNUmakefile in %@", _appDir);
                return NO;
            }
        }
        if (_verbose) NSLog(@"make_appimage: using %@ (source=%d)", _appDir, !isPrebuiltBundle);
    }

    // === (b) Install to AppDir ===
    {
        [fm removeItemAtPath:_appDirPath error:NULL];

        NSString *usrBin = [_appDirPath stringByAppendingPathComponent:@"usr/bin"];
        NSString *usrLib = [_appDirPath stringByAppendingPathComponent:@"usr/lib"];

        NSError *err = nil;
        if (![fm createDirectoryAtPath:usrBin
          withIntermediateDirectories:YES attributes:nil error:&err]) {
            NSLog(@"make_appimage: Failed to create %@: %@", usrBin, err);
            return NO;
        }
        if (![fm createDirectoryAtPath:usrLib
          withIntermediateDirectories:YES attributes:nil error:&err]) {
            NSLog(@"make_appimage: Failed to create %@: %@", usrLib, err);
            return NO;
        }

        if (isPrebuiltBundle) {
            NSString *bundleName = [_appDir lastPathComponent];
            NSString *destPath = [usrBin stringByAppendingPathComponent:bundleName];
            if (![fm copyItemAtPath:_appDir toPath:destPath error:&err]) {
                NSLog(@"make_appimage: Failed to copy bundle: %@", err);
                return NO;
            }
            if (_verbose) NSLog(@"make_appimage: copied bundle to %@", destPath);
        } else if (makePath) {
            @try {
                NSTask *task = [[NSTask alloc] init];
                [task setLaunchPath:makePath];
                [task setArguments:@[@"install",
                    [NSString stringWithFormat:@"DESTDIR=%@", _appDirPath]]];
                [task setCurrentDirectoryPath:_appDir];

                NSPipe *errPipe = [NSPipe pipe];
                [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
                [task setStandardError:errPipe];

                if (_verbose) NSLog(@"make_appimage: make install DESTDIR=%@", _appDirPath);
                [task launch];
                [task waitUntilExit];

                if ([task terminationStatus] != 0) {
                    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
                    NSString *errStr = [[NSString alloc] initWithData:errData
                                                             encoding:NSUTF8StringEncoding];
                    NSLog(@"make_appimage: make install failed: %@", errStr);
                    return NO;
                }
            } @catch (NSException *exception) {
                NSLog(@"make_appimage: make install exception: %@", exception);
                return NO;
            }
        } else {
            NSLog(@"make_appimage: 'make' not found in PATH");
            return NO;
        }
    }

    // === (c) Copy GNUstep system tools ===
    if (gnustepConfigPath) {
        NSString *toolsDir = [self _runTool:gnustepConfigPath
                                   withArgs:@[@"--variable=GNUSTEP_SYSTEM_TOOLS"]];
        if (toolsDir) {
            NSString *localBin = [_appDirPath stringByAppendingPathComponent:@"usr/local/bin"];
            [fm createDirectoryAtPath:localBin withIntermediateDirectories:YES
                           attributes:nil error:NULL];

            for (NSString *tool in @[@"gdnc", @"gpbs", @"make_services"]) {
                @try {
                    NSString *src = [toolsDir stringByAppendingPathComponent:tool];
                    NSString *dst = [localBin stringByAppendingPathComponent:tool];
                    if ([fm fileExistsAtPath:src]) {
                        [fm copyItemAtPath:src toPath:dst error:NULL];
                    }
                } @catch (NSException *exception) {
                    if (_verbose) NSLog(@"make_appimage: failed to copy %@: %@", tool, [exception reason]);
                }
            }
        }
    }

    // === (d) Create GNUstep config and copy bundles ===
    if (_verbose) NSLog(@"make_appimage: creating GNUstep config");
    {
        NSString *gsLibDir = [_appDirPath stringByAppendingPathComponent:@"usr/lib/GNUstep"];
        [fm createDirectoryAtPath:gsLibDir withIntermediateDirectories:YES
                       attributes:nil error:NULL];

        NSString *configPath = [gsLibDir stringByAppendingPathComponent:@"GNUstep.conf"];
        NSString *content =
            @"GNUSTEP_USER_CONFIG_FILE=\n"
             "GNUSTEP_USER_DEFAULTS_DIR=GNUstep/Defaults\n"
             "GNUSTEP_SYSTEM_LIBRARIES=../../../System/Library\n"
             "GNUSTEP_SYSTEM_LIBRARY=../../../System/Library\n"
             "GNUSTEP_SYSTEM_TOOLS=../../../System/Library/Tools\n"
             "GNUSTEP_NETWORK_LIBRARIES=../../../System/Library\n"
             "GNUSTEP_NETWORK_LIBRARY=../../../System/Library\n"
             "GNUSTEP_NETWORK_TOOLS=../../../System/Library/Tools\n"
             "GNUSTEP_LOCAL_LIBRARIES=../../../Local/Library\n"
             "GNUSTEP_LOCAL_LIBRARY=../../../Local/Library\n"
             "GNUSTEP_LOCAL_TOOLS=../../../Local/Library/Tools\n"
             "GNUSTEP_USER_DIR_LIBRARIES=../../../Local/Library\n"
             "GNUSTEP_USER_DIR_LIBRARY=../../../Local/Library\n"
             "GNUSTEP_USER_DIR_TOOLS=../../../Local/Library/Tools\n";

        NSError *err = nil;
        if (![content writeToFile:configPath atomically:YES
                         encoding:NSUTF8StringEncoding error:&err]) {
            NSLog(@"make_appimage: Failed to write GNUstep.conf: %@", err);
        }

        if (chmodPath) {
            [self _runTool:chmodPath withArgs:@[@"g-w", configPath] error:NULL];
        }

        // Copy only essential bundles: backend (libgnustep-back-* and libgnustep-xlib-*)
        NSString *bundlesDir = [_appDirPath stringByAppendingPathComponent:@"System/Library/Bundles"];
        NSSet *bundlePrefixes = [NSSet setWithObjects:@"libgnustep-back-", @"libgnustep-xlib-", nil];
        NSArray *srcBundlesDirs = @[@"/System/Library/Bundles", @"/Local/Library/Bundles"];
        for (NSString *src in srcBundlesDirs) {
            if ([fm fileExistsAtPath:src]) {
                [fm createDirectoryAtPath:bundlesDir withIntermediateDirectories:YES
                               attributes:nil error:NULL];
                NSArray *entries = [fm contentsOfDirectoryAtPath:src error:NULL];
                for (NSString *entry in entries) {
                    BOOL wanted = NO;
                    for (NSString *prefix in bundlePrefixes) {
                        if ([entry hasPrefix:prefix]) { wanted = YES; break; }
                    }
                    if (!wanted) continue;
                    NSString *fullSrc = [src stringByAppendingPathComponent:entry];
                    NSString *fullDst = [bundlesDir stringByAppendingPathComponent:entry];
                    if (![fm fileExistsAtPath:fullDst]) {
                        [fm copyItemAtPath:fullSrc toPath:fullDst error:NULL];
                    }
                }
            }
        }

        // Copy themes from System and Local Library
        NSString *themesDir = [_appDirPath stringByAppendingPathComponent:@"System/Library/Themes"];
        NSArray *srcThemesDirs = @[@"/System/Library/Themes", @"/Local/Library/Themes"];
        for (NSString *src in srcThemesDirs) {
            if ([fm fileExistsAtPath:src]) {
                [fm createDirectoryAtPath:themesDir withIntermediateDirectories:YES
                               attributes:nil error:NULL];
                NSArray *entries = [fm contentsOfDirectoryAtPath:src error:NULL];
                for (NSString *entry in entries) {
                    NSString *fullSrc = [src stringByAppendingPathComponent:entry];
                    NSString *fullDst = [themesDir stringByAppendingPathComponent:entry];
                    if (![fm fileExistsAtPath:fullDst]) {
                        [fm copyItemAtPath:fullSrc toPath:fullDst error:NULL];
                    }
                }
            }
        }
    }

    // === (e) Resolve library dependencies ===
    {
        LibraryResolver *resolver = [[LibraryResolver alloc] initWithAppDir:_appDirPath];
        [resolver setVerbose:_verbose];
        [resolver setStandalone:_standalone];
        NSArray *elfs = [resolver findAllELFsInAppDir];
        [_allELFs addObjectsFromArray:elfs];

        NSArray *deps = [resolver resolveDependenciesForExecutables:elfs];
        [_seenDeps addObjectsFromArray:deps];

        LibraryDeployer *deployer = [[LibraryDeployer alloc] initWithAppDir:_appDirPath];
        [deployer setStandalone:_standalone];
        [deployer setVerbose:_verbose];
        if (![deployer deployLibraries:deps]) {
            NSLog(@"make_appimage: deployLibraries failed");
        }

        if (_verbose) {
            NSLog(@"make_appimage: %lu ELFs, %lu dependencies", (unsigned long)[elfs count], (unsigned long)[deps count]);
        }
    }

    // === (f) Deploy ld-linux interpreter ===
    NSString *detectedInterpreter = nil;
    {
        InterpreterDeployer *deployer = [[InterpreterDeployer alloc] initWithAppDir:_appDirPath];
        [deployer setVerbose:_verbose];
        detectedInterpreter = [deployer detectInterpreter];
        if (detectedInterpreter) {
            if (_verbose) NSLog(@"make_appimage: interpreter: %@", detectedInterpreter);
            [deployer deployInterpreter:detectedInterpreter];
            // ld-linux is deployed but NOT patched — patching it breaks $ORIGIN
            // resolution in RPATH.  The patched default search paths are not
            // needed when rpath and LD_LIBRARY_PATH are set to AppDir paths.
        }
    }

    // === (g) Backend bundle symlink and deps ===
    {
        NSString *bundlesDir = [_appDirPath stringByAppendingPathComponent:@"System/Library/Bundles"];
        if ([fm fileExistsAtPath:bundlesDir]) {
            NSArray *bundleEntries = [fm contentsOfDirectoryAtPath:bundlesDir error:NULL];
            NSString *backendBundle = nil;
            for (NSString *entry in bundleEntries) {
                if ([entry hasPrefix:@"libgnustep-back-"] && [entry hasSuffix:@".bundle"]) {
                    backendBundle = entry;
                    break;
                }
            }
            if (backendBundle) {
                NSString *symlinkPath = [bundlesDir stringByAppendingPathComponent:@"libgnustep-back.bundle"];
                [fm removeItemAtPath:symlinkPath error:NULL];
                [fm createSymbolicLinkAtPath:symlinkPath withDestinationPath:backendBundle error:NULL];

                NSString *backendExecName = [backendBundle stringByDeletingPathExtension];
                NSString *target = [[bundlesDir stringByAppendingPathComponent:backendBundle]
                    stringByAppendingPathComponent:backendExecName];
                LibraryResolver *br = [[LibraryResolver alloc] initWithAppDir:_appDirPath];
                [br setVerbose:_verbose];
                [br setStandalone:_standalone];
                NSArray *bdeps = [br resolveDependenciesForExecutables:@[target]];
                LibraryDeployer *bd = [[LibraryDeployer alloc] initWithAppDir:_appDirPath];
                [bd setStandalone:_standalone];
                [bd setVerbose:_verbose];
                [bd deployLibraries:bdeps];
            }
        }
    }

    // === (h) Determine main executable ===
    {
        if ([_mainExec length] == 0) {
            NSArray *searchDirs = @[
                [_appDirPath stringByAppendingPathComponent:@"usr/bin"],
                [_appDirPath stringByAppendingPathComponent:@"Local/Applications"],
                [_appDirPath stringByAppendingPathComponent:@"System/Applications"],
                [_appDirPath stringByAppendingPathComponent:@"usr/local/bin"],
                _appDirPath,
            ];

            for (NSString *searchDir in searchDirs) {
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:searchDir isDirectory:&isDir] || !isDir) continue;

                NSArray *entries = [fm contentsOfDirectoryAtPath:searchDir error:NULL];
                for (NSString *entry in entries) {
                    NSString *full = [searchDir stringByAppendingPathComponent:entry];
                    BOOL eIsDir = NO;
                    if (![fm fileExistsAtPath:full isDirectory:&eIsDir]) continue;

                    if ([[entry pathExtension] isEqualToString:@"app"]) {
                        NSString *execName = [entry stringByDeletingPathExtension];
                        NSString *bundleExec = [full stringByAppendingPathComponent:execName];
                        if ([fm isExecutableFileAtPath:bundleExec]) {
                            _mainExec = [[searchDir stringByAppendingPathComponent:entry]
                                stringByAppendingPathComponent:execName];
                            if ([_mainExec hasPrefix:_appDirPath])
                                _mainExec = [_mainExec substringFromIndex:[_appDirPath length] + 1];
                            break;
                        }
                        NSString *resExec = [full stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"Resources/%@", execName]];
                        if ([fm isExecutableFileAtPath:resExec]) {
                            _mainExec = [[searchDir stringByAppendingPathComponent:entry]
                                stringByAppendingPathComponent:[NSString stringWithFormat:@"Resources/%@", execName]];
                            if ([_mainExec hasPrefix:_appDirPath])
                                _mainExec = [_mainExec substringFromIndex:[_appDirPath length] + 1];
                            break;
                        }
                    } else if (!eIsDir && [fm isExecutableFileAtPath:full]) {
                        if ([entry isEqualToString:_appName] ||
                            [entry isEqualToString:[_appName lastPathComponent]]) {
                            _mainExec = [searchDir stringByAppendingPathComponent:entry];
                            if ([_mainExec hasPrefix:_appDirPath])
                                _mainExec = [_mainExec substringFromIndex:[_appDirPath length] + 1];
                            break;
                        }
                        if (!_mainExec) {
                            NSString *candidate = [searchDir stringByAppendingPathComponent:entry];
                            if ([candidate hasPrefix:_appDirPath])
                                candidate = [candidate substringFromIndex:[_appDirPath length] + 1];
                            _mainExec = candidate;
                        }
                    }
                }
                if (_mainExec) break;
            }
        }

        if (!_mainExec) {
            NSLog(@"make_appimage: Could not determine main executable");
            return NO;
        }
        if (_verbose) NSLog(@"make_appimage: main executable: %@", _mainExec);

        // Determine Resources dir for this app (contains bundled .so files)
        _appResourcesDir = nil;
        NSString *mainDir = [_mainExec stringByDeletingLastPathComponent];
        if ([[mainDir pathExtension] isEqualToString:@"app"]) {
            _appResourcesDir = [mainDir stringByAppendingPathComponent:@"Resources"];
        } else {
            NSString *parent = [mainDir stringByDeletingLastPathComponent];
            if ([[parent pathExtension] isEqualToString:@"app"])
                _appResourcesDir = [parent stringByAppendingPathComponent:@"Resources"];
        }

        if (detectedInterpreter && patchelfPath) {
            NSString *mainFullPath = [_appDirPath stringByAppendingPathComponent:_mainExec];
            NSString *relInterp = [@"." stringByAppendingString:detectedInterpreter];
            [self _runTool:patchelfPath withArgs:@[@"--set-interpreter", relInterp, mainFullPath] error:NULL];
            if (_verbose) NSLog(@"make_appimage: set interpreter to %@", relInterp);
        }
    }

    // === (i) Determine theme to use ===
    // Detect the current system theme and bundle it.  GNUSTEP_THEME is set
    // in AppRun so the app uses the same theme it would have on the host.
    NSString *themeName = nil;
    NSString *appRunThemeLine = @"";
    {
        NSString *defaultsPath = [self _findTool:@"defaults"];
        if (defaultsPath) {
            NSString *result = [self _runTool:defaultsPath withArgs:@[@"read", @"NSGlobalDomain", @"GSTheme"]];
            if ([result length] > 0) {
                NSString *themeDir = [_appDirPath stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"System/Library/Themes/%@.theme", result]];
                if ([[NSFileManager defaultManager] fileExistsAtPath:themeDir]) {
                    themeName = result;
                }
            }
        }
        // Fallback: use the first theme found in the AppDir
        if (!themeName) {
            NSString *themesDir = [_appDirPath stringByAppendingPathComponent:@"System/Library/Themes"];
            NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:themesDir error:NULL];
            for (NSString *entry in entries) {
                if ([entry hasSuffix:@".theme"]) {
                    themeName = [entry stringByDeletingPathExtension];
                    break;
                }
            }
        }
        if (themeName) {
            appRunThemeLine = [NSString stringWithFormat:@"export GNUSTEP_THEME=%@\n", themeName];
            NSLog(@"make_appimage: using theme %@", themeName);
        }
    }

    // === (j) Patch RPATH on all deployed ELFs ===
    // Use $ORIGIN-relative rpaths so libraries resolve inside the AppDir.
    if (patchelfPath && _standalone) {
        if (_verbose) NSLog(@"make_appimage: patching RPATH on deployed ELFs");
        // Collect all ELFs: initial scan + usr/lib + usr/local/lib
        NSMutableSet *elfSet = [NSMutableSet setWithArray:_allELFs];
        NSString *usrLib = [_appDirPath stringByAppendingPathComponent:@"usr/lib"];
        for (NSString *sub in [fm enumeratorAtPath:usrLib]) {
            NSString *full = [usrLib stringByAppendingPathComponent:sub];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir)
                [elfSet addObject:full];
        }
        for (NSString *sub in [fm enumeratorAtPath:[_appDirPath stringByAppendingPathComponent:@"usr/local/lib"]]) {
            NSString *full = [[_appDirPath stringByAppendingPathComponent:@"usr/local/lib"] stringByAppendingPathComponent:sub];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir)
                [elfSet addObject:full];
        }

        for (NSString *elf in elfSet) {
            NSString *existing = [self _runTool:patchelfPath withArgs:@[@"--print-rpath", elf]];
            NSMutableSet *parts = [NSMutableSet set];
            if ([existing length] > 0) {
                for (NSString *p in [existing componentsSeparatedByString:@":"])
                    if (![p hasPrefix:@"/"] && [p length] > 0)
                        [parts addObject:p];
            }

            // $ORIGIN-relative path from this ELF to usr/lib
            NSString *elfDir = [elf stringByDeletingLastPathComponent];
            NSMutableString *rel = [NSMutableString string];
            NSArray *e = [elfDir pathComponents], *l = [usrLib pathComponents];
            NSUInteger c = 0;
            while (c < [e count] && c < [l count] && [[e objectAtIndex:c] isEqual:[l objectAtIndex:c]]) c++;
            for (NSUInteger i = c; i < [e count]; i++) [rel appendString:@"../"];
            for (NSUInteger i = c; i < [l count]; i++) [rel appendFormat:@"%@/", [l objectAtIndex:i]];
            if ([rel length] == 0) [rel appendString:@"../"];
            [parts addObject:[NSString stringWithFormat:@"$ORIGIN/%@", rel]];

            // If this is inside a .app bundle, keep its existing Resources rpath
            // The original $ORIGIN/Resources is already preserved above.

            NSString *combined = [[parts allObjects] componentsJoinedByString:@":"];
            if (![existing isEqualToString:combined] && [parts count] > 0) {
                if (_verbose) NSLog(@"make_appimage:   rpath %@ -> %@", [elf lastPathComponent], combined);
                [self _runTool:patchelfPath withArgs:@[@"--set-rpath", combined, elf] error:NULL];
            }
        }
    }

    // === (k) Verify all needed libraries are present in the AppDir ===
    if (_verbose && _standalone) {
        NSString *vUsrLib = [_appDirPath stringByAppendingPathComponent:@"usr/lib"];
        NSMutableSet *missing = [NSMutableSet set];
        for (NSString *dep in _seenDeps) {
            if ([dep hasPrefix:_appDirPath]) continue;
            NSString *basename = [dep lastPathComponent];
            if (![fm fileExistsAtPath:[vUsrLib stringByAppendingPathComponent:basename]])
                [missing addObject:basename];
        }
        if ([missing count] > 0) {
            NSLog(@"make_appimage: %lu libs missing from AppDir:", (unsigned long)[missing count]);
            for (NSString *lib in missing) NSLog(@"make_appimage:   MISSING: %@", lib);
        } else {
            NSLog(@"make_appimage: all %lu deps present", (unsigned long)[_seenDeps count]);
        }
    }

    // === (l) Create AppRun ===
    {
        NSString *appRunPath = [_appDirPath stringByAppendingPathComponent:@"AppRun"];
        NSMutableString *content = [NSMutableString string];
        [content appendString:@"#!/bin/sh\n"];
        [content appendString:@"# Unset host environment variables that could interfere\n"];
        [content appendString:@"unset LD_LIBRARY_PATH GNUSTEP_CONFIG_FILE GNUSTEP_USER_CONFIG_FILE GNUSTEP_USER_DIR GNUSTEP_USER_DEFAULTS_DIR\n"];
        [content appendString:@"unset GNUSTEP_SYSTEM_ROOT GNUSTEP_LOCAL_ROOT GNUSTEP_NETWORK_ROOT GNUSTEP_FLATTENED\n"];
        [content appendString:@"unset LD_PRELOAD LD_AUDIT LD_DEBUG LD_ORIGIN_PATH\n"];
        [content appendString:@"\n"];
        [content appendString:@"HERE=\"$(dirname \"$(readlink -f \"${0}\")\")\"\n"];
        [content appendFormat:@"export GNUSTEP_CONFIG_FILE=\"$HERE/usr/lib/GNUstep/GNUstep.conf\"\n"];
        if (themeName) {
            [content appendFormat:@"export GNUSTEP_THEME=%@\n", themeName];
        }
        [content appendString:@"export FONTCONFIG_FILE=/etc/fonts/fonts.conf\n"];
        [content appendString:@"export FONTCONFIG_PATH=/etc/fonts\n"];
        [content appendString:@"export GNUSTEP_ROOT=\"$HERE/usr\"\n"];
        [content appendString:@"export GNUSTEP_SYSTEM_ROOT=\"$HERE/System\"\n"];
        [content appendString:@"export GNUSTEP_LOCAL_ROOT=\"$HERE/Local\"\n"];
        // All library resolution is via RPATH — no LD_LIBRARY_PATH needed
        [content appendString:@"export PATH=\"$HERE/usr/local/bin:$HERE/usr/bin:$HERE/System/Library/Tools:$HERE/Local/Library/Tools:$PATH\"\n"];
        [content appendString:@"\n"];
        [content appendString:@"cd \"$HERE\"\n"];
        [content appendFormat:@"exec \"$HERE/%@\" \"$@\"\n", _mainExec];

        NSError *err = nil;
        if (![content writeToFile:appRunPath atomically:YES
                         encoding:NSUTF8StringEncoding error:&err]) {
            NSLog(@"make_appimage: Failed to write AppRun: %@", err);
            return NO;
        }

        if (chmodPath) {
            [self _runTool:chmodPath withArgs:@[@"+x", appRunPath] error:NULL];
        }
    }

    // === (j) Create .desktop file ===
    {
        NSString *iconName = _appName;
        NSArray *extensions = @[@"png", @"svg", @"xpm"];
        NSString *foundIcon = nil;
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:_appDirPath];
        NSString *subpath;
        while ((subpath = [enumerator nextObject])) {
            if ([extensions containsObject:[[subpath pathExtension] lowercaseString]]) {
                foundIcon = [_appDirPath stringByAppendingPathComponent:subpath];
                iconName = [[subpath lastPathComponent] stringByDeletingPathExtension];
                break;
            }
        }

        if (foundIcon) {
            NSString *rootIcon = [_appDirPath stringByAppendingPathComponent:[foundIcon lastPathComponent]];
            if (![fm fileExistsAtPath:rootIcon]) {
                [fm copyItemAtPath:foundIcon toPath:rootIcon error:NULL];
            }
        }

        NSString *version = @"1.0";
        if (isPrebuiltBundle) {
            NSString *plistPath = [_appDir stringByAppendingPathComponent:@"Resources/Info-gnustep.plist"];
            if ([fm fileExistsAtPath:plistPath]) {
                NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
                NSString *plistVersion = [plist objectForKey:@"CFBundleVersion"];
                if ([plistVersion length] > 0) version = plistVersion;
            }
        } else {
            NSString *makefileContent = [NSString stringWithContentsOfFile:
                [_appDir stringByAppendingPathComponent:@"GNUmakefile"]
                                                                 encoding:NSUTF8StringEncoding error:NULL];
            if (makefileContent) {
                for (NSString *line in [makefileContent componentsSeparatedByString:@"\n"]) {
                    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                    if ([trimmed hasPrefix:@"VERSION"] || [trimmed hasPrefix:@"PACKAGE_VERSION"]) {
                        NSRange eq = [trimmed rangeOfString:@"="];
                        if (eq.location != NSNotFound) {
                            NSString *val = [[trimmed substringFromIndex:eq.location + 1]
                                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                            if ([val length] > 0) { version = val; break; }
                        }
                    }
                }
            }
        }

        NSString *appBasename = [[_appName lastPathComponent] stringByDeletingPathExtension];
        NSString *desktopPath = [_appDirPath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.desktop", appBasename]];
        NSString *desktopContent = [NSString stringWithFormat:
            @"[Desktop Entry]\nType=Application\nName=%@\nComment=%@\nExec=%@\nIcon=%@\nCategories=%@\nTerminal=false\n",
            appBasename, _comment ?: @"", _mainExec, iconName, _categories ?: @"Application"];

        NSError *err = nil;
        if (![desktopContent writeToFile:desktopPath atomically:YES
                                encoding:NSUTF8StringEncoding error:&err]) {
            NSLog(@"make_appimage: Failed to write desktop file: %@", err);
            return NO;
        }
    }

    // === (k) Package AppImage ===
    {
        NSString *arch = nil, *os = nil;
        NSString *unamePath = [self _findTool:@"uname"];
        if (unamePath) {
            arch = [self _runTool:unamePath withArgs:@[@"-m"]];
            os = [self _runTool:unamePath withArgs:@[@"-s"]];
        }

        if (!_outputFile) {
            NSString *osLower = os ? [os lowercaseString] : @"linux";
            _outputFile = [NSString stringWithFormat:@"%@-%@-%@.AppImage",
                           _appName, arch ?: @"unknown", osLower];
        }

        if ([fm fileExistsAtPath:_appimageTool]) {
            NSError *err = nil;
            if (![self _runTool:_appimageTool withArgs:@[_appDirPath, _outputFile] error:&err]) {
                NSLog(@"make_appimage: appimagetool failed: %@", err);
            } else {
                NSLog(@"make_appimage: AppImage created: %@", _outputFile);
            }
        } else {
            NSLog(@"make_appimage: appimagetool not found; AppDir ready at %@", _appDirPath);
        }
    }

    return YES;
}

@end
