/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AppImagePackager.h"
#import "BundleBuilder.h"

@interface AppImagePackager ()
{
    BundleBuilder *_builder;
    NSString *_appimageTool;
    NSString *_outputFile;
}
- (NSString *)_runTool:(NSString *)tool withArgs:(NSArray *)args;
- (NSString *)_findTool:(NSString *)name;
@end

@implementation AppImagePackager

- (instancetype)initWithBuilder:(BundleBuilder *)builder
{
    self = [super init];
    if (self) {
        _builder = builder;
        _appimageTool = @"appimagetool";
    }
    return self;
}

- (void)setAppimageTool:(NSString *)path  { _appimageTool = [path copy]; }
- (void)setOutputFile:(NSString *)path    { _outputFile = [path copy]; }

- (NSString *)_findTool:(NSString *)name
{
    if ([name isAbsolutePath]) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:name]) return name;
        return nil;
    }
    NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    for (NSString *dir in [pathEnv componentsSeparatedByString:@":"]) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:full]) return full;
    }
    return nil;
}

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
        return [[[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } @catch (NSException *e) {
        return nil;
    }
}

- (BOOL)package
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appDirPath = [_builder appDirPath];
    NSString *appName = [_builder appName];
    NSString *mainExec = [_builder mainExec];
    NSString *comment = [_builder comment];
    NSString *categories = [_builder categories];

    // Create .desktop file
    {
        NSString *appBasename = [[appName lastPathComponent] stringByDeletingPathExtension];
        NSString *desktopPath = [appDirPath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.desktop", appBasename]];
        NSString *desktopContent = [NSString stringWithFormat:
            @"[Desktop Entry]\nType=Application\nName=%@\nComment=%@\nExec=%@\nIcon=%@\nCategories=%@\nTerminal=false\n",
            appBasename, comment ?: @"", mainExec,
            [[appBasename stringByDeletingPathExtension] lastPathComponent],
            categories ?: @"Application"];

        NSError *err = nil;
        if (![desktopContent writeToFile:desktopPath atomically:YES
                                encoding:NSUTF8StringEncoding error:&err]) {
            NSLog(@"make_appimage: Failed to write desktop file: %@", err);
            return NO;
        }
    }

    // Determine output filename if not set
    if (!_outputFile) {
        NSString *arch = nil, *os = nil;
        NSString *unamePath = [self _findTool:@"uname"];
        if (unamePath) {
            arch = [self _runTool:unamePath withArgs:@[@"-m"]];
            os = [self _runTool:unamePath withArgs:@[@"-s"]];
        }
        NSString *osLower = os ? [os lowercaseString] : @"linux";
        _outputFile = [NSString stringWithFormat:@"%@-%@-%@.AppImage",
                       appName, arch ?: @"unknown", osLower];
    }

    // Run appimagetool
    if ([fm fileExistsAtPath:_appimageTool]) {
        if (![self _runTool:_appimageTool withArgs:@[appDirPath, _outputFile]]) {
            NSLog(@"make_appimage: appimagetool failed");
            return NO;
        }
        NSLog(@"make_appimage: AppImage created: %@", _outputFile);
    } else {
        NSLog(@"make_appimage: appimagetool not found; AppDir ready at %@", appDirPath);
    }

    return YES;
}

@end
