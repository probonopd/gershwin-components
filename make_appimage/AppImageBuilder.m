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

- (NSString *)_runTool:(NSString *)tool withArgs:(NSArray *)args;
- (BOOL)_runTool:(NSString *)tool withArgs:(NSArray *)args error:(NSError **)error;

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
    }
    return self;
}

- (void)setOutputFile:(NSString *)path       { _outputFile = [path copy]; }
- (void)setBuildDirectory:(NSString *)dir    { _buildDir = [dir copy]; _appDirPath = [_buildDir stringByAppendingPathComponent:@"AppDir"]; }
- (void)setComment:(NSString *)comment        { _comment = [comment copy]; }
- (void)setCategories:(NSString *)categories  { _categories = [categories copy]; }
- (void)setMainExecutable:(NSString *)path   { _mainExec = [path copy]; }
- (void)setAppimageTool:(NSString *)path      { _appimageTool = [path copy]; }

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

    // (a) Find the application source directory
    {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:_appName isDirectory:&isDir] && isDir) {
            _appDir = _appName;
        } else {
            NSString *appBundle = [_appName stringByAppendingPathExtension:@"app"];
            if ([fm fileExistsAtPath:appBundle isDirectory:&isDir] && isDir) {
                _appDir = appBundle;
            } else {
                _appDir = _appName;
            }
        }

        NSString *makefile = [_appDir stringByAppendingPathComponent:@"GNUmakefile"];
        if (![fm fileExistsAtPath:makefile]) {
            NSLog(@"AppImageBuilder: No GNUmakefile found in %@", _appDir);
            return NO;
        }
    }

    // (b) Build and install to AppDir
    {
        NSString *usrBin = [_appDirPath stringByAppendingPathComponent:@"usr/bin"];
        NSString *usrLib = [_appDirPath stringByAppendingPathComponent:@"usr/lib"];

        NSError *err = nil;
        if (![fm createDirectoryAtPath:usrBin
          withIntermediateDirectories:YES attributes:nil error:&err]) {
            NSLog(@"AppImageBuilder: Failed to create %@: %@", usrBin, err);
            return NO;
        }
        if (![fm createDirectoryAtPath:usrLib
          withIntermediateDirectories:YES attributes:nil error:&err]) {
            NSLog(@"AppImageBuilder: Failed to create %@: %@", usrLib, err);
            return NO;
        }

        @try {
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"/usr/bin/make"];
            [task setArguments:@[@"install",
                [NSString stringWithFormat:@"DESTDIR=%@", _appDirPath]]];
            [task setCurrentDirectoryPath:_appDir];

            NSPipe *errPipe = [NSPipe pipe];
            [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
            [task setStandardError:errPipe];

            [task launch];
            [task waitUntilExit];

            if ([task terminationStatus] != 0) {
                NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
                NSString *errStr = [[NSString alloc] initWithData:errData
                                                         encoding:NSUTF8StringEncoding];
                NSLog(@"AppImageBuilder: make install failed: %@", errStr);
                return NO;
            }
        } @catch (NSException *exception) {
            NSLog(@"AppImageBuilder: make install exception: %@", exception);
            return NO;
        }
    }

    // (c) Copy GNUstep system tools
    {
        NSString *toolsDir = [self _runTool:@"/usr/bin/gnustep-config"
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
                    NSLog(@"AppImageBuilder: Failed to copy %@: %@", tool, [exception reason]);
                }
            }
        }
    }

    // (d) Create GNUstep config
    {
        NSString *etcDir = [_appDirPath stringByAppendingPathComponent:@"usr/etc/GNUstep"];
        [fm createDirectoryAtPath:etcDir withIntermediateDirectories:YES
                       attributes:nil error:NULL];

        NSString *configPath = [etcDir stringByAppendingPathComponent:@"GNUstep.conf"];
        NSString *content = @"GNUSTEP_USER_CONFIG_FILE=.GNUstep.conf\n"
                             "GNUSTEP_USER_DEFAULTS_DIR=GNUstep/Defaults\n"
                             "GNUSTEP_SYSTEM_USERS_DIR=/home\n"
                             "GNUSTEP_NETWORK_USERS_DIR=/home\n"
                             "GNUSTEP_LOCAL_USERS_DIR=/home\n"
                             "GNUSTEP_SYSTEM_LIBRARY=../../lib/GNUstep\n"
                             "GNUSTEP_LOCAL_LIBRARY=../../lib/GNUstep\n"
                             "GNUSTEP_NETWORK_LIBRARY=../../lib/GNUstep\n"
                             "GNUSTEP_SYSTEM_TOOLS=../../local/bin\n"
                             "GNUSTEP_LOCAL_TOOLS=../../local/bin\n";

        NSError *err = nil;
        if (![content writeToFile:configPath atomically:YES
                         encoding:NSUTF8StringEncoding error:&err]) {
            NSLog(@"AppImageBuilder: Failed to write GNUstep.conf: %@", err);
        }

        [self _runTool:@"/bin/chmod" withArgs:@[@"600", configPath] error:NULL];
    }

    // (e) Resolve library dependencies
    {
        LibraryResolver *resolver = [[LibraryResolver alloc] initWithAppDir:_appDirPath];
        NSArray *elfs = [resolver findAllELFsInAppDir];
        [_allELFs addObjectsFromArray:elfs];

        NSArray *deps = [resolver resolveDependenciesForExecutables:elfs];
        [_seenDeps addObjectsFromArray:deps];

        LibraryDeployer *deployer = [[LibraryDeployer alloc] initWithAppDir:_appDirPath];
        if (![deployer deployLibraries:deps]) {
            NSLog(@"AppImageBuilder: deployLibraries failed");
        }
    }

    // (f) Deploy ld-linux interpreter
    {
        InterpreterDeployer *deployer = [[InterpreterDeployer alloc] initWithAppDir:_appDirPath];
        NSString *interp = [deployer detectInterpreter];
        if (interp) {
            if ([deployer deployInterpreter:interp]) {
                NSString *deployedPath = [_appDirPath stringByAppendingPathComponent:interp];
                [deployer patchInterpreter:deployedPath];
            }
        }
    }

    // (g) Bundle GNUstep backends
    {
        NSString *libDirs = [self _runTool:@"/usr/bin/gnustep-config"
                                   withArgs:@[@"--variable=GNUSTEP_LIBRARIES_DIRS"]];
        if (libDirs) {
            NSString *bundlesDir = [_appDirPath
                stringByAppendingPathComponent:@"usr/lib/GNUstep/Bundles"];

            for (NSString *dir in [libDirs componentsSeparatedByString:@" "]) {
                if ([dir length] == 0) continue;

                NSString *srcBundles = [dir stringByAppendingPathComponent:@"GNUstep/Bundles"];
                BOOL isBundlesDir = NO;
                if (![fm fileExistsAtPath:srcBundles isDirectory:&isBundlesDir] || !isBundlesDir)
                    continue;

                [fm createDirectoryAtPath:bundlesDir withIntermediateDirectories:YES
                               attributes:nil error:NULL];

                NSArray *entries = [fm contentsOfDirectoryAtPath:srcBundles error:NULL];
                for (NSString *entry in entries) {
                    NSString *src = [srcBundles stringByAppendingPathComponent:entry];
                    NSString *dst = [bundlesDir stringByAppendingPathComponent:entry];
                    if (![fm fileExistsAtPath:dst]) {
                        [fm copyItemAtPath:src toPath:dst error:NULL];
                    }
                }
            }

            NSArray *bundleEntries = [fm contentsOfDirectoryAtPath:bundlesDir error:NULL];
            NSString *backendBundle = nil;
            for (NSString *entry in bundleEntries) {
                if ([entry hasPrefix:@"libgnustep-back-"] && [entry hasSuffix:@".bundle"]) {
                    backendBundle = entry;
                    break;
                }
            }

            if (backendBundle) {
                NSString *symlinkPath = [bundlesDir
                    stringByAppendingPathComponent:@"libgnustep-back.bundle"];
                [fm removeItemAtPath:symlinkPath error:NULL];
                [fm createSymbolicLinkAtPath:symlinkPath
                         withDestinationPath:backendBundle error:NULL];

                NSString *target = [bundlesDir stringByAppendingPathComponent:backendBundle];
                LibraryResolver *br = [[LibraryResolver alloc] initWithAppDir:_appDirPath];
                NSArray *bdeps = [br resolveDependenciesForExecutables:@[target]];
                LibraryDeployer *bd = [[LibraryDeployer alloc] initWithAppDir:_appDirPath];
                [bd deployLibraries:bdeps];
            }
        }
    }

    // (h) Determine main executable
    {
        if ([_mainExec length] == 0) {
            NSString *usrBin = [_appDirPath stringByAppendingPathComponent:@"usr/bin"];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:usrBin isDirectory:&isDir] && isDir) {
                NSArray *entries = [fm contentsOfDirectoryAtPath:usrBin error:NULL];
                for (NSString *entry in entries) {
                    NSString *full = [usrBin stringByAppendingPathComponent:entry];
                    BOOL eIsDir = NO;
                    if ([fm fileExistsAtPath:full isDirectory:&eIsDir] && !eIsDir &&
                        [fm isExecutableFileAtPath:full]) {
                        if ([entry isEqualToString:_appName]) {
                            _mainExec = [@"usr/bin" stringByAppendingPathComponent:entry];
                            break;
                        }
                        if (!_mainExec) {
                            _mainExec = [@"usr/bin" stringByAppendingPathComponent:entry];
                        }
                    }
                }
            }
        }

        if (!_mainExec) {
            NSLog(@"AppImageBuilder: Could not determine main executable");
            return NO;
        }
    }

    // (i) Create AppRun
    {
        NSString *appRunPath = [_appDirPath stringByAppendingPathComponent:@"AppRun"];
        NSString *content = [NSString stringWithFormat:
            @"#!/bin/sh\n"
            @"HERE=\"$(dirname \"$(readlink -f \"${0}\")\")\"\n"
            @"export GNUSTEP_CONFIG_FILE=\"$HERE/usr/etc/GNUstep/GNUstep.conf\"\n"
            @"export LD_LIBRARY_PATH=\"$HERE/usr/lib:$HERE/usr/local/lib:$HERE/libc:$LD_LIBRARY_PATH\"\n"
            @"export PATH=\"$HERE/usr/local/bin:$HERE/usr/bin:$PATH\"\n"
            @"exec \"$HERE/%@\" \"$@\"\n",
            _mainExec];

        NSError *err = nil;
        if (![content writeToFile:appRunPath atomically:YES
                         encoding:NSUTF8StringEncoding error:&err]) {
            NSLog(@"AppImageBuilder: Failed to write AppRun: %@", err);
            return NO;
        }

        [self _runTool:@"/bin/chmod" withArgs:@[@"+x", appRunPath] error:NULL];
    }

    // (j) Create .desktop file
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
            NSString *rootIcon = [_appDirPath stringByAppendingPathComponent:
                [foundIcon lastPathComponent]];
            if (![fm fileExistsAtPath:rootIcon]) {
                [fm copyItemAtPath:foundIcon toPath:rootIcon error:NULL];
            }
        }

        NSString *version = @"1.0";
        NSString *makefileContent = [NSString stringWithContentsOfFile:
            [_appDir stringByAppendingPathComponent:@"GNUmakefile"]
                                                             encoding:NSUTF8StringEncoding
                                                                error:NULL];
        if (makefileContent) {
            for (NSString *line in [makefileContent componentsSeparatedByString:@"\n"]) {
                NSString *trimmed = [line stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                if ([trimmed hasPrefix:@"VERSION"] || [trimmed hasPrefix:@"PACKAGE_VERSION"]) {
                    NSRange eq = [trimmed rangeOfString:@"="];
                    if (eq.location != NSNotFound) {
                        NSString *val = [[trimmed substringFromIndex:eq.location + 1]
                            stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]];
                        if ([val length] > 0) {
                            version = val;
                            break;
                        }
                    }
                }
            }
        }

        NSString *desktopPath = [_appDirPath
            stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.desktop", _appName]];
        NSString *desktopContent = [NSString stringWithFormat:
            @"[Desktop Entry]\n"
            @"Type=Application\n"
            @"Name=%@\n"
            @"Comment=%@\n"
            @"Exec=%@\n"
            @"Icon=%@\n"
            @"Categories=%@\n"
            @"Terminal=false\n",
            _appName, _comment ?: @"", _mainExec, iconName, _categories ?: @"Application"];

        NSError *err = nil;
        if (![desktopContent writeToFile:desktopPath atomically:YES
                                encoding:NSUTF8StringEncoding error:&err]) {
            NSLog(@"AppImageBuilder: Failed to write desktop file: %@", err);
            return NO;
        }
    }

    // (k) Package AppImage
    {
        NSString *arch = [self _runTool:@"/usr/bin/uname" withArgs:@[@"-m"]];
        NSString *os = [self _runTool:@"/usr/bin/uname" withArgs:@[@"-s"]];

        if (!_outputFile) {
            NSString *osLower = os ? [os lowercaseString] : @"linux";
            _outputFile = [NSString stringWithFormat:@"%@-%@-%@.AppImage",
                           _appName, arch ?: @"unknown", osLower];
        }

        if ([fm fileExistsAtPath:_appimageTool]) {
            NSError *err = nil;
            if (![self _runTool:_appimageTool
                        withArgs:@[_appDirPath, _outputFile]
                           error:&err]) {
                NSLog(@"AppImageBuilder: appimagetool failed: %@", err);
            }
        } else {
            NSLog(@"AppImageBuilder: appimagetool not found at %@, skipping packaging",
                  _appimageTool);
        }
    }

    return YES;
}

@end
