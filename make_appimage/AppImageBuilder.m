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
    BOOL _standaloneBundle;
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

- (NSString *)_gnustepPath
{
    return [_appDirPath stringByAppendingPathComponent:@"Resources/GNUstep"];
}

- (NSString *)_gnustepLibraryPath
{
    return [[self _gnustepPath] stringByAppendingPathComponent:@"Library"];
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
- (void)setExtraBundles:(NSArray *)names       { _extraBundles = [names copy]; }
- (void)setVerbose:(BOOL)flag                 { _verbose = flag; }
- (void)setStandaloneBundle:(BOOL)flag        { _standaloneBundle = flag; }

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
        _appDir = nil;
        if ([fm fileExistsAtPath:_appName isDirectory:&isDir] && isDir) {
            _appDir = _appName;
        } else {
            NSString *appBundle = [_appName stringByAppendingPathExtension:@"app"];
            if ([fm fileExistsAtPath:appBundle isDirectory:&isDir] && isDir) {
                _appDir = appBundle;
            }
        }
        if (_appDir == nil) {
            // Search standard application directories
            NSArray *appDirs = @[
                @"/System/Applications", @"/Local/Applications",
                @"/usr/local/bin", @"/usr/bin",
                [@"~" stringByExpandingTildeInPath]
            ];
            for (NSString *dir in appDirs) {
                NSString *candidate = [dir stringByAppendingPathComponent:
                    [_appName stringByAppendingPathExtension:@"app"]];
                if ([fm fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
                    _appDir = candidate;
                    break;
                }
            }
        }
        if (_appDir == nil) {
            // Last resort: current directory
            if ([fm fileExistsAtPath:_appName isDirectory:&isDir] && isDir) {
                _appDir = _appName;
            } else {
                NSString *appBundle = [_appName stringByAppendingPathExtension:@"app"];
                if ([fm fileExistsAtPath:appBundle isDirectory:&isDir] && isDir) {
                    _appDir = appBundle;
                }
            }
        }
        if (_appDir) {
            if ([[_appDir pathExtension] isEqualToString:@"app"]) {
                NSString *makefile = [_appDir stringByAppendingPathComponent:@"GNUmakefile"];
                isPrebuiltBundle = ![fm fileExistsAtPath:makefile];
            } else {
                isPrebuiltBundle = NO;
            }
        } else {
            _appDir = _appName;
            isPrebuiltBundle = NO;
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

    // === (b) Install application to AppDir ===
    // The .app bundle IS the AppDir — the application binary goes at the root
    // (e.g. AppDir/Workspace) and its resources at AppDir/Resources/.
    // GNUstep dependencies are deployed separately into Resources/GNUstep/.
    {
        [fm removeItemAtPath:_appDirPath error:NULL];
        NSError *err = nil;
        [fm createDirectoryAtPath:_appDirPath withIntermediateDirectories:YES
                        attributes:nil error:NULL];

        if (isPrebuiltBundle) {
            // Copy the .app bundle CONTENTS directly to AppDir root
            NSArray *items = [fm contentsOfDirectoryAtPath:_appDir error:NULL];
            for (NSString *item in items) {
                NSString *src = [_appDir stringByAppendingPathComponent:item];
                NSString *dst = [_appDirPath stringByAppendingPathComponent:item];
                if (![fm copyItemAtPath:src toPath:dst error:&err]) {
                    NSLog(@"make_appimage: Failed to copy %@: %@", item, err);
                    // stamp.make is a build artifact, skip it
                    if ([item isEqualToString:@"stamp.make"]) continue;
                    return NO;
                }
            }
            if (_verbose) NSLog(@"make_appimage: deployed bundle contents to %@", _appDirPath);
        } else if (makePath) {
            // Build into a temp DESTDIR, then move the .app bundle to AppDir
            NSString *tempDir = [_buildDir stringByAppendingPathComponent:@"destdir"];
            [fm removeItemAtPath:tempDir error:NULL];
            @try {
                NSTask *task = [[NSTask alloc] init];
                [task setLaunchPath:makePath];
                [task setArguments:@[@"install",
                    [NSString stringWithFormat:@"DESTDIR=%@", tempDir]]];
                [task setCurrentDirectoryPath:_appDir];

                NSPipe *errPipe = [NSPipe pipe];
                [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
                [task setStandardError:errPipe];

                if (_verbose) NSLog(@"make_appimage: make install DESTDIR=%@", tempDir);
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

            // Find the .app bundle inside the temp DESTDIR
            NSArray *appDirs = @[@"System/Applications", @"Applications",
                                 @"Local/Applications", @"usr/bin"];
            NSString *bundlePath = nil;
            for (NSString *relDir in appDirs) {
                NSString *dir = [tempDir stringByAppendingPathComponent:relDir];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
                NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:NULL];
                for (NSString *entry in entries) {
                    if ([[entry pathExtension] isEqualToString:@"app"]) {
                        bundlePath = [dir stringByAppendingPathComponent:entry];
                        break;
                    }
                }
                if (bundlePath) break;
            }

            if (!bundlePath) {
                NSLog(@"make_appimage: Could not find .app bundle in DESTDIR");
                return NO;
            }

            NSArray *items = [fm contentsOfDirectoryAtPath:bundlePath error:NULL];
            for (NSString *item in items) {
                NSString *src = [bundlePath stringByAppendingPathComponent:item];
                NSString *dst = [_appDirPath stringByAppendingPathComponent:item];
                if (![fm copyItemAtPath:src toPath:dst error:&err]) {
                    NSLog(@"make_appimage: Failed to copy %@: %@", item, err);
                    return NO;
                }
            }
            [fm removeItemAtPath:tempDir error:NULL];
            if (_verbose) NSLog(@"make_appimage: deployed bundle from %@", bundlePath);
        } else {
            NSLog(@"make_appimage: 'make' not found in PATH");
            return NO;
        }
    }

    // === (c) Copy GNUstep system tools ===
    // Deploy services (gdnc, gpbs, make_services) and Workspace helper
    // daemons (fswatcher, ddbd, mdextractor) so the bundled app can find
    // them via NSTask launchPathForTool: at runtime.
    // Tools are placed in Resources/GNUstep/Library/Tools/.
    {
        NSString *toolsDir = [[self _gnustepLibraryPath] stringByAppendingPathComponent:@"Tools"];
        [fm createDirectoryAtPath:toolsDir withIntermediateDirectories:YES
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
                    NSString *dst = [toolsDir stringByAppendingPathComponent:tool];
                    if (![fm fileExistsAtPath:dst]) {
                        [fm copyItemAtPath:src toPath:dst error:NULL];
                    }
                }
            } @catch (NSException *exception) {
                if (_verbose) NSLog(@"make_appimage: failed to copy %@: %@", tool, [exception reason]);
            }
        }
    }

    // === (d) Create GNUstep config and copy GNUstep components ===
    // All GNUstep components (config, bundles, frameworks, themes, images)
    // go under Resources/GNUstep/Library/ inside the .app bundle.
    if (_verbose) NSLog(@"make_appimage: creating GNUstep layout");
    {
        NSString *gsLibDir = [self _gnustepLibraryPath];
        [fm createDirectoryAtPath:gsLibDir withIntermediateDirectories:YES
                       attributes:nil error:NULL];

        // GNUstep.conf — relative paths resolve from Resources/GNUstep/GNUstep.conf
        // back to the GNUstep Library directory alongside it.
        NSString *configPath = [[self _gnustepPath] stringByAppendingPathComponent:@"GNUstep.conf"];
        NSString *content =
            @"GNUSTEP_SYSTEM_LIBRARIES=./Library\n"
              "GNUSTEP_SYSTEM_LIBRARY=./Library\n"
              "GNUSTEP_SYSTEM_TOOLS=./Library/Tools\n";

        NSError *err = nil;
        if (![content writeToFile:configPath atomically:YES
                         encoding:NSUTF8StringEncoding error:&err]) {
            NSLog(@"make_appimage: Failed to write GNUstep.conf: %@", err);
        }

        if (chmodPath) {
            [self _runTool:chmodPath withArgs:@[@"g-w", configPath] error:NULL];
        }

        // Always deploy backend bundles (libgnustep-back-*, libgnustep-xlib-*).
        // Additional bundles needed by the app at runtime (thumbnailers, finder
        // modules, inspectors, etc.) can be specified via setExtraBundles:.
        NSString *bundlesDir = [gsLibDir stringByAppendingPathComponent:@"Bundles"];
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
                    if (!wanted && [_extraBundles containsObject:entry]) {
                        wanted = YES;
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

        // Fix backend bundle version
        for (NSString *entry in [fm contentsOfDirectoryAtPath:bundlesDir error:NULL]) {
            if ([entry hasPrefix:@"libgnustep-back-"] && [entry hasSuffix:@".bundle"]) {
                NSString *plistPath = [bundlesDir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@/Resources/Info-gnustep.plist", entry]];
                NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
                if (plist) {
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

        // Copy frameworks
        {
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
            NSString *frameworksDir = [gsLibDir stringByAppendingPathComponent:@"Frameworks"];
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

        // Copy themes
        if (_deployTheme) {
            NSString *themesDir = [gsLibDir stringByAppendingPathComponent:@"Themes"];
            if (_themeName) {
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

        // Copy system Images (nsmapping.strings, common_* fallback images)
        {
            NSString *imagesDir = [gsLibDir stringByAppendingPathComponent:@"Images"];
            if (![fm fileExistsAtPath:imagesDir]) {
                for (NSString *src in @[@"/System/Library/Images", @"/Local/Library/Images"]) {
                    if ([fm fileExistsAtPath:src]) {
                        [fm copyItemAtPath:src toPath:imagesDir error:NULL];
                        if (_verbose) NSLog(@"make_appimage: deployed %@", src);
                        break;
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
        NSString *bundlesDir = [[self _gnustepLibraryPath] stringByAppendingPathComponent:@"Bundles"];
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
    // In the new layout, the .app bundle IS the AppDir, so the main
    // executable sits at the AppDir root (e.g. AppDir/Workspace).
    {
        if ([_mainExec length] == 0) {
            NSArray *searchDirs = @[
                _appDirPath,
                [_appDirPath stringByAppendingPathComponent:@"Resources"],
            ];

            for (NSString *searchDir in searchDirs) {
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:searchDir isDirectory:&isDir] || !isDir) continue;

                NSArray *entries = [fm contentsOfDirectoryAtPath:searchDir error:NULL];
                for (NSString *entry in entries) {
                    NSString *full = [searchDir stringByAppendingPathComponent:entry];
                    BOOL eIsDir = NO;
                    if (![fm fileExistsAtPath:full isDirectory:&eIsDir]) continue;
                    if (eIsDir || ![fm isExecutableFileAtPath:full]) continue;

                    // Skip AppImage metadata files
                    if ([entry isEqualToString:@"AppRun"] ||
                        [entry hasSuffix:@".desktop"] ||
                        [entry hasSuffix:@".plist"]) continue;

                    // Match by app name first
                    if ([entry isEqualToString:_appName] ||
                        [entry isEqualToString:[_appName lastPathComponent]]) {
                        _mainExec = entry;
                        break;
                    }
                    // Fallback: use the first executable found
                    if (!_mainExec) _mainExec = entry;
                }
                if (_mainExec) break;
            }
        }

        if (!_mainExec) {
            NSLog(@"make_appimage: Could not determine main executable");
            return NO;
        }
        if (_verbose) NSLog(@"make_appimage: main executable: %@", _mainExec);

        // Resources dir is at AppDir/Resources/
        _appResourcesDir = [_appDirPath stringByAppendingPathComponent:@"Resources"];

        // Patch the interpreter on ALL deployed ELFs so every binary and
        // library uses the bundled ld-linux (deployed to Resources/<basename>).
        // This prevents helper processes (gdnc, gpbs, make_services) from
        // trying to load the host's ld-linux when executed from a directory
        // outside the AppDir root.
        if (detectedInterpreter && patchelfPath) {
            NSMutableSet *interpElfs = [NSMutableSet setWithArray:_allELFs];
            NSString *iLibDir = [[self _gnustepLibraryPath] stringByAppendingPathComponent:@"Libraries"];
            for (NSString *sub in [fm enumeratorAtPath:iLibDir]) {
                NSString *full = [iLibDir stringByAppendingPathComponent:sub];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir)
                    [interpElfs addObject:full];
            }
            // ld-linux is deployed to Resources/GNUstep/Library/Libraries/<basename>.
            // The ./ prefix makes the kernel resolve it relative to CWD (which
            // AppRun sets to the AppDir root by calling chdir(here)).
            NSString *interpBase = [detectedInterpreter lastPathComponent];
            NSString *relInterp = [@"." stringByAppendingPathComponent:
                [@"Resources/GNUstep/Library/Libraries" stringByAppendingPathComponent:interpBase]];
            if (_verbose) NSLog(@"make_appimage: interpreter relative path: %@", relInterp);
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
                    NSString *themeDir = [[self _gnustepLibraryPath] stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"Themes/%@.theme", result]];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:themeDir]) {
                        themeName = result;
                    }
                }
            }
            // Fallback: use the first theme found in the AppDir
            if (!themeName) {
                NSString *themesDir = [[self _gnustepLibraryPath] stringByAppendingPathComponent:@"Themes"];
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
        NSString *libDir = [[self _gnustepLibraryPath] stringByAppendingPathComponent:@"Libraries"];
        NSMutableSet *elfSet = [NSMutableSet setWithArray:_allELFs];
        for (NSString *sub in [fm enumeratorAtPath:libDir]) {
            NSString *full = [libDir stringByAppendingPathComponent:sub];
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

            // $ORIGIN-relative path from this ELF to Libraries/
            // If the ELF is already in Libraries/, no RPATH needed (LD_LIBRARY_PATH covers it).
            NSString *elfDir = [elf stringByDeletingLastPathComponent];
            if ([elfDir isEqualToString:libDir]) continue;
            NSMutableString *rel = [NSMutableString string];
            NSArray *e = [elfDir pathComponents], *l = [libDir pathComponents];
            NSUInteger c = 0;
            while (c < [e count] && c < [l count] && [[e objectAtIndex:c] isEqual:[l objectAtIndex:c]]) c++;
            for (NSUInteger i = c; i < [e count]; i++) [rel appendString:@"../"];
            for (NSUInteger i = c; i < [l count]; i++) [rel appendFormat:@"%@/", [l objectAtIndex:i]];
            if ([rel length] == 0) [rel appendString:@"../"];
            [parts addObject:[NSString stringWithFormat:@"$ORIGIN/%@", rel]];

            NSString *combined = [[parts allObjects] componentsJoinedByString:@":"];
            if (![existing isEqualToString:combined] && [parts count] > 0) {
                if (_verbose) NSLog(@"make_appimage:   rpath %@ -> %@", [elf lastPathComponent], combined);
                [self _runTool:patchelfPath withArgs:@[@"--set-rpath", combined, elf] error:NULL];
            }
        }
    }

    // === (k) Verify all needed libraries are present in the AppDir ===
    if (_verbose && _standalone) {
        NSString *vLibDir = [[self _gnustepLibraryPath] stringByAppendingPathComponent:@"Libraries"];
        NSMutableSet *missing = [NSMutableSet set];
        for (NSString *dep in _seenDeps) {
            if ([dep hasPrefix:_appDirPath]) continue;
            NSString *basename = [dep lastPathComponent];
            if (![fm fileExistsAtPath:[vLibDir stringByAppendingPathComponent:basename]])
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
        // Placed in Resources/GNUstep/Library/Preferences/ so NSUserDefaults
        // finds it via GNUSTEP_SYSTEM_ROOT/Library/Preferences/.
        if (themeName) {
            NSString *defaultsDir = [[self _gnustepLibraryPath] stringByAppendingPathComponent:@"Preferences"];
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

    // === (j) Create .desktop file and .DirIcon ===
    {
        NSString *iconName = _appName;
        NSString *foundIcon = nil;

        // Read icon from the app's Info.plist (takes precedence over scan)
        NSString *plistPath = [_appDirPath stringByAppendingPathComponent:@"Resources/Info-gnustep.plist"];
        if (![fm fileExistsAtPath:plistPath]) {
            plistPath = [_appDirPath stringByAppendingPathComponent:@"Resources/Info.plist"];
        }
        if ([fm fileExistsAtPath:plistPath]) {
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            NSString *plistIcon = nil;
            for (NSString *key in @[@"ApplicationIcon", @"NSIcon", @"CFBundleIconFile", @"GSThemeIcon"]) {
                plistIcon = [plist objectForKey:key];
                if ([plistIcon length] > 0) break;
            }
            if ([plistIcon length] > 0) {
                // Search in Resources/ for the icon file
                NSArray *extensions = @[@"png", @"svg", @"xpm", @"tiff", @"icns", @"ico"];
                NSString *iconBase = [plistIcon stringByDeletingPathExtension];
                NSString *iconExt = [plistIcon pathExtension];
                if ([iconExt length] > 0) {
                    // Full filename with extension given
                    NSString *fullPath = [_appDirPath stringByAppendingPathComponent:
                        [@"Resources" stringByAppendingPathComponent:plistIcon]];
                    if ([fm fileExistsAtPath:fullPath]) {
                        foundIcon = fullPath;
                        iconName = iconBase;
                    }
                } else {
                    // No extension — try known extensions
                    for (NSString *ext in extensions) {
                        NSString *fullPath = [_appDirPath stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"Resources/%@.%@", plistIcon, ext]];
                        if ([fm fileExistsAtPath:fullPath]) {
                            foundIcon = fullPath;
                            iconName = iconBase;
                            break;
                        }
                    }
                }
            }
        }

        // Fallback: scan AppDir for any image file
        if (!foundIcon) {
            NSArray *extensions = @[@"png", @"svg", @"xpm"];
            NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:_appDirPath];
            NSString *subpath;
            while ((subpath = [enumerator nextObject])) {
                if ([extensions containsObject:[[subpath pathExtension] lowercaseString]]) {
                    foundIcon = [_appDirPath stringByAppendingPathComponent:subpath];
                    iconName = [[subpath lastPathComponent] stringByDeletingPathExtension];
                    break;
                }
            }
        }

        // Copy icon to .DirIcon (used by appimagetool as the AppImage icon)
        if (foundIcon) {
            NSString *dirIcon = [_appDirPath stringByAppendingPathComponent:@".DirIcon"];
            if (![fm fileExistsAtPath:dirIcon]) {
                [fm copyItemAtPath:foundIcon toPath:dirIcon error:NULL];
            }
            // Also copy to root with original name for appimagetool's icon detection
            NSString *rootIcon = [_appDirPath stringByAppendingPathComponent:[foundIcon lastPathComponent]];
            if (![fm fileExistsAtPath:rootIcon]) {
                [fm copyItemAtPath:foundIcon toPath:rootIcon error:NULL];
            }
        }

        NSString *version = @"1.0";
        if (isPrebuiltBundle) {
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

    // === (k) Finalize ===
    if (_standaloneBundle) {
        NSString *plistPath = [_appDirPath stringByAppendingPathComponent:@"Resources/Info-gnustep.plist"];
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
        if (plist) {
            [plist setObject:@"AppRun" forKey:@"NSExecutable"];
            [plist writeToFile:plistPath atomically:YES];
        }
        // Strip path and .app extension to get the bare app name
        NSString *bareName = [_appDir lastPathComponent];
        if ([[bareName pathExtension] isEqualToString:@"app"])
            bareName = [bareName stringByDeletingPathExtension];
        NSString *desktopPath = [_appDirPath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.desktop", bareName]];
        [fm removeItemAtPath:desktopPath error:NULL];
        NSString *appBundleName = [bareName stringByAppendingPathExtension:@"app"];
        NSString *bundlePath = [[_appDirPath stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:appBundleName];
        [fm removeItemAtPath:bundlePath error:NULL];
        [fm moveItemAtPath:_appDirPath toPath:bundlePath error:NULL];
        NSLog(@"make_standalone: standalone .app bundle created at %@", bundlePath);
    } else {
        // Standard AppImage packaging
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
