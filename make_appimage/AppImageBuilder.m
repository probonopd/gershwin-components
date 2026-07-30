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
    BOOL _deployTheme;
    BOOL _verbose;
    NSString *_themeName;
    NSArray *_frameworks;
    NSString *_appResourcesDir;
}

- (NSString *)_runTool:(NSString *)tool withArgs:(NSArray *)args;
- (BOOL)_runTool:(NSString *)tool withArgs:(NSArray *)args error:(NSError **)error;
- (NSString *)_findTool:(NSString *)name;
- (NSArray *)_detectNeededFrameworks;

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
        // Standalone mode bundles ALL libraries (including libc) so the
        // AppImage works on any Linux/BSD distro without host dependencies.
        _standalone = YES;
        _deployTheme = YES;
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
- (void)setThemeName:(NSString *)name          { _themeName = [name copy]; }
- (void)setDeployTheme:(BOOL)flag              { _deployTheme = flag; }
- (void)setFrameworks:(NSArray *)names         { _frameworks = [names copy]; }
- (void)setVerbose:(BOOL)flag                 { _verbose = flag; }

#pragma mark - Tool path lookup

// Use PATH-based lookup instead of hardcoding paths so the same
// tool works across Linux and BSD where tool locations differ.
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

#pragma mark - Framework auto-detection

- (NSArray *)_detectNeededFrameworks
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *libDir = [_appDirPath stringByAppendingPathComponent:@"usr/lib"];
    NSMutableArray *needed = [NSMutableArray array];

    NSArray *frameworkSearchDirs = @[@"/System/Library/Frameworks", @"/Local/Library/Frameworks"];
    for (NSString *fwDir in frameworkSearchDirs) {
        NSArray *entries = [fm contentsOfDirectoryAtPath:fwDir error:NULL];
        for (NSString *entry in entries) {
            if (![entry hasSuffix:@".framework"]) continue;
            NSString *fwName = [entry stringByDeletingPathExtension];
            // Check if any library matching this framework exists in AppDir
            NSString *pattern = [NSString stringWithFormat:@"lib%@.so", fwName];
            NSArray *libs = [fm contentsOfDirectoryAtPath:libDir error:NULL];
            for (NSString *lib in libs) {
                if ([lib hasPrefix:pattern]) {
                    [needed addObject:fwName];
                    break;
                }
            }
        }
    }
    if (_verbose) NSDebugLLog(@"make_appimage", @"Auto-detected frameworks: %@", needed);
    return needed;
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
    // Deploy services (gdnc, gpbs, make_services) and Workspace helper
    // daemons (fswatcher, ddbd, mdextractor) so the bundled app can find
    // them via NSTask launchPathForTool: at runtime.
    {
        NSString *localBin = [_appDirPath stringByAppendingPathComponent:@"usr/local/bin"];
        [fm createDirectoryAtPath:localBin withIntermediateDirectories:YES
                       attributes:nil error:NULL];

        NSArray *toolsToDeploy = @[@"gdnc", @"gpbs", @"make_services",
                                   @"fswatcher", @"ddbd", @"mdextractor"];
        NSArray *toolSearchDirs = @[gnustepConfigPath ?
            [self _runTool:gnustepConfigPath withArgs:@[@"--variable=GNUSTEP_SYSTEM_TOOLS"]] : nil,
            gnustepConfigPath ?
            [self _runTool:gnustepConfigPath withArgs:@[@"--variable=GNUSTEP_LOCAL_TOOLS"]] : nil,
            @"/System/Library/Tools", @"/Local/Library/Tools"];
        for (NSString *tool in toolsToDeploy) {
            @try {
                NSString *src = nil;
                for (NSString *dir in toolSearchDirs) {
                    if ([dir length] == 0) continue;
                    NSString *candidate = [dir stringByAppendingPathComponent:tool];
                    if ([fm fileExistsAtPath:candidate]) {
                        src = candidate; break;
                    }
                }
                if (src) {
                    NSString *dst = [localBin stringByAppendingPathComponent:tool];
                    if (![fm fileExistsAtPath:dst]) {
                        [fm copyItemAtPath:src toPath:dst error:NULL];
                    }
                }
            } @catch (NSException *exception) {
                if (_verbose) NSLog(@"make_appimage: failed to copy %@: %@", tool, [exception reason]);
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
        // Relative paths (../../../) are resolved by GNUstep relative to the
        // config file's own location (usr/lib/GNUstep/GNUstep.conf), pointing
        // up to the AppDir root.  Using absolute paths would break when the
        // AppImage is mounted at a different path on each run.
        NSString *content =
            @"GNUSTEP_SYSTEM_LIBRARIES=../../../System/Library\n"
              "GNUSTEP_SYSTEM_LIBRARY=../../../System/Library\n"
              "GNUSTEP_SYSTEM_TOOLS=../../../System/Library/Tools\n";

        NSError *err = nil;
        if (![content writeToFile:configPath atomically:YES
                         encoding:NSUTF8StringEncoding error:&err]) {
            NSLog(@"make_appimage: Failed to write GNUstep.conf: %@", err);
        }

        if (chmodPath) {
            [self _runTool:chmodPath withArgs:@[@"g-w", configPath] error:NULL];
        }

        // Only deploy backend bundles (libgnustep-back-*, libgnustep-xlib-*).
        // Preference panes, finders, etc. are not needed at runtime inside an
        // AppImage sandbox and would bloat the image unnecessarily.
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
                        // Resolve symlinks: the host may have absolute symlinks
                        // (e.g. libgnustep-xlib-032.bundle -> /System/Library/Bundles/...)
                        // that would break inside the AppDir.  Copy the resolved target.
                        NSDictionary *attr = [fm attributesOfItemAtPath:fullSrc error:NULL];
                        if ([[attr fileType] isEqual:NSFileTypeSymbolicLink]) {
                            NSString *resolved = [self _runTool:@"readlink"
                                                      withArgs:@[@"-f", fullSrc]];
                            if ([resolved length] > 0 && [fm fileExistsAtPath:resolved]) {
                                [fm copyItemAtPath:resolved toPath:fullDst error:NULL];
                            }
                        } else {
                            [fm copyItemAtPath:fullSrc toPath:fullDst error:NULL];
                        }
                    }
                }
            }
        }

        // Fix backend bundle version: Some GNUstep versions compare the
        // version number extracted from the bundle NAME (e.g. "032" from
        // "libgnustep-back-032.bundle") against the expected version.
        // Set GSBundleVersion to match the name-based version "032" so
        // both checks pass regardless of version formatting differences.
        for (NSString *entry in [fm contentsOfDirectoryAtPath:bundlesDir error:NULL]) {
            if ([entry hasPrefix:@"libgnustep-back-"] && [entry hasSuffix:@".bundle"]) {
                NSString *plistPath = [bundlesDir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@/Resources/Info-gnustep.plist", entry]];
                NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
                if (plist) {
                    // Extract version from bundle name: "libgnustep-back-032.bundle" -> "032"
                    NSString *nameVersion = [[entry stringByReplacingOccurrencesOfString:@"libgnustep-back-"
                                                                              withString:@""]
                                               stringByReplacingOccurrencesOfString:@".bundle"
                                                                         withString:@""];
                    if ([nameVersion length] > 0) {
                        [plist setObject:nameVersion forKey:@"GSBundleVersion"];
                        [plist setObject:nameVersion forKey:@"GSBundleShortVersionString"];
                        [plist writeToFile:plistPath atomically:YES];
                        if (_verbose) NSLog(@"make_appimage: set bundle version to %@ (from name %@)",
                                              nameVersion, [entry lastPathComponent]);
                    }
                }
            }
        }

        // Copy frameworks from System and Local Library
        {
            // Auto-detect needed frameworks when none explicitly specified
            NSArray *frameworksToDeploy = _frameworks;
            if (!frameworksToDeploy) {
                frameworksToDeploy = [self _detectNeededFrameworks];
                if ([frameworksToDeploy count] == 0) {
                    NSLog(@"make_appimage: no frameworks detected; deploying all");
                    frameworksToDeploy = nil;
                } else if (_verbose) {
                    NSLog(@"make_appimage: auto-detected %lu frameworks", (unsigned long)[frameworksToDeploy count]);
                }
            }
            NSString *frameworksDir = [_appDirPath stringByAppendingPathComponent:@"System/Library/Frameworks"];
            for (NSString *src in @[@"/System/Library/Frameworks", @"/Local/Library/Frameworks"]) {
                if ([fm fileExistsAtPath:src]) {
                    NSArray *entries = [fm contentsOfDirectoryAtPath:src error:NULL];
                    for (NSString *entry in entries) {
                        if (![entry hasSuffix:@".framework"]) continue;
                        NSString *name = [entry stringByDeletingPathExtension];
                        if (frameworksToDeploy && ![frameworksToDeploy containsObject:name]) continue;
                        NSString *fullSrc = [src stringByAppendingPathComponent:entry];
                        NSString *fullDst = [frameworksDir stringByAppendingPathComponent:entry];
                        if (![fm fileExistsAtPath:fullDst]) {
                            [fm createDirectoryAtPath:frameworksDir withIntermediateDirectories:YES
                                           attributes:nil error:NULL];
                            [fm copyItemAtPath:fullSrc toPath:fullDst error:NULL];
                            if (_verbose) NSLog(@"make_appimage: deployed framework %@", name);
                        }
                    }
                }
            }
        }

        // Copy themes from System and Local Library
        if (_deployTheme) {
            NSString *themesDir = [_appDirPath stringByAppendingPathComponent:@"System/Library/Themes"];
            if (_themeName) {
                // Deploy only the specified theme
                NSString *themeDirName = [_themeName stringByAppendingPathExtension:@"theme"];
                for (NSString *src in @[@"/System/Library/Themes", @"/Local/Library/Themes"]) {
                    NSString *fullSrc = [src stringByAppendingPathComponent:themeDirName];
                    if ([fm fileExistsAtPath:fullSrc]) {
                        [fm createDirectoryAtPath:themesDir withIntermediateDirectories:YES
                                       attributes:nil error:NULL];
                        NSString *fullDst = [themesDir stringByAppendingPathComponent:themeDirName];
                        if (![fm fileExistsAtPath:fullDst]) {
                            [fm copyItemAtPath:fullSrc toPath:fullDst error:NULL];
                        }
                        break;
                    }
                }
            } else {
                // Deploy all available themes
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
        }

    }

    // === (e) Resolve library dependencies ===
    // In standalone mode (default), the resolver deploys ALL dependencies
    // including libc and ld-linux.  There is no exclusion list because the
    // AppImage must run on any target distro regardless of library versions.
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
            // The interpreter is deployed into the AppDir but its search paths
            // are NOT patched.  Patching ld-linux's built-in search paths breaks
            // $ORIGIN expansion in RPATH because the patched loader resolves
            // $ORIGIN relative to the patched search path prefix instead of the
            // binary's actual location.  The default search paths are irrelevant
            // here since we set LD_LIBRARY_PATH and RPATH to AppDir paths.
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

        // Patch the interpreter on ALL deployed ELFs so every binary and
        // library uses the bundled ld-linux.  This prevents helper processes
        // (gdnc, gpbs, make_services) from trying to load the host's ld-linux
        // when executed from a directory outside the AppDir root.
        if (detectedInterpreter && patchelfPath) {
            NSMutableSet *interpElfs = [NSMutableSet setWithArray:_allELFs];
            NSString *iUsrLib = [_appDirPath stringByAppendingPathComponent:@"usr/lib"];
            for (NSString *sub in [fm enumeratorAtPath:iUsrLib]) {
                NSString *full = [iUsrLib stringByAppendingPathComponent:sub];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir)
                    [interpElfs addObject:full];
            }
            NSString *relInterp = [@"." stringByAppendingString:detectedInterpreter];
            for (NSString *elf in interpElfs) {
                [self _runTool:patchelfPath
                      withArgs:@[@"--set-interpreter", relInterp, elf]
                         error:NULL];
            }
            if (_verbose) NSLog(@"make_appimage: set relative interpreter on %lu ELFs",
                                (unsigned long)[interpElfs count]);
        }
    }

    // === (i) Determine theme to use ===
    // Detect the current system theme at build time (via `defaults read`) and
    // hardcode it into AppRun.  We bake it in rather than detecting at runtime
    // because the host may not have GNUstep installed or the theme directory
    // may differ inside the AppImage.  Hardcoding avoids needing `defaults`
    // (or a working GNUstep installation) on the end user's machine.
    // If --theme was given on the command line, use that directly.
    // If --no-theme was given, skip detection entirely.
    NSString *themeName = nil;
    if (_deployTheme) {
        if (_themeName) {
            themeName = _themeName;
        } else {
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
        }
        if (themeName) {
            NSLog(@"make_appimage: using theme %@", themeName);
        }
    }

    // === (j) Patch RPATH on all deployed ELFs ===
    // Use RPATH instead of LD_LIBRARY_PATH so child processes (e.g. services
    // launched by the app) also resolve libraries inside the AppDir.  RPATH is
    // baked into the ELF and always applied; LD_LIBRARY_PATH must be inherited
    // through the process tree and can be stripped by setuid binaries or
    // sanitized environments.
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

    // === (l) Create AppRun (precompiled static binary + settings plist) ===
    // AppRun is compiled once during `make` and is the same for every AppImage.
    // It reads app-specific settings from AppRun.plist, which we write here.
    // No compiler needed at packaging time — running make_appimage does not
    // require gcc or any C development tools.
    {
        NSString *appRunPath = [_appDirPath stringByAppendingPathComponent:@"AppRun"];
        NSString *appRunSrc = nil;
        NSString *toolPath = [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
        NSString *toolDir = [toolPath stringByDeletingLastPathComponent];
        for (NSString *p in @[[toolDir stringByAppendingPathComponent:@"AppRun"],
                               @"/System/Library/Tools/AppRun"]) {
            if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) {
                appRunSrc = p; break;
            }
        }
        if (appRunSrc) {
            [[NSFileManager defaultManager] copyItemAtPath:appRunSrc toPath:appRunPath error:NULL];
        }

        // Write app-specific settings to AppRun.plist
        NSString *plistPath = [_appDirPath stringByAppendingPathComponent:@"AppRun.plist"];
        NSString *themeValue = themeName ?: @"";
        NSString *plist = [NSString stringWithFormat:
            @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            @"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            @"<plist version=\"1.0\">\n"
            @"<dict>\n"
            @"  <key>mainExecutable</key>\n"
            @"  <string>%@</string>\n"
            @"  <key>theme</key>\n"
            @"  <string>%@</string>\n"
            @"</dict>\n"
            @"</plist>\n",
            _mainExec, themeValue];
        [plist writeToFile:plistPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        // Write GNUstep NSGlobalDomain defaults with the selected theme.
        // GNUSTEP_THEME env var is read too late by some GNUstep versions,
        // so we put GSTheme into NSGlobalDomain.plist where NSUserDefaults
        // finds it immediately.  XML plist format (not old-style) required.
        if (themeName) {
            NSString *defaultsDir = [_appDirPath stringByAppendingPathComponent:@"GNUstep/Defaults"];
            [fm createDirectoryAtPath:defaultsDir withIntermediateDirectories:YES attributes:nil error:NULL];
            NSString *plistPath = [defaultsDir stringByAppendingPathComponent:@"NSGlobalDomain.plist"];
            NSString *xml = [NSString stringWithFormat:
                @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
                @"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                @"<plist version=\"1.0\">\n"
                @"<dict>\n"
                @"    <key>GSTheme</key>\n"
                @"    <string>%@</string>\n"
                @"</dict>\n"
                @"</plist>\n",
                themeName];
            [xml writeToFile:plistPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }

        if (![fm fileExistsAtPath:appRunPath]) {
            NSLog(@"make_appimage: FATAL: precompiled AppRun not found — "
                  "run 'make install' in the make_appimage source dir first");
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
