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
+ (NSString *)_findTool:(NSString *)name;
- (NSString *)_runTool:(NSString *)tool withArgs:(NSArray *)args;
- (NSString *)_installIconForDesktopIcon:(NSString *)desktopIcon inDir:(NSString *)appDirPath;
@end

@implementation AppImagePackager

+ (BOOL)findAppImageTool
{
    return [self _findTool:@"appimagetool"] != nil;
}

+ (NSString *)_findTool:(NSString *)name
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
        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        if ([task terminationStatus] != 0) return nil;
        return [[[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } @catch (NSException *e) {
        return nil;
    }
}

- (NSString *)_installIconForDesktopIcon:(NSString *)desktopIcon inDir:(NSString *)appDirPath
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *resourcesDir = [appDirPath stringByAppendingPathComponent:@"Resources"];
    NSString *plistPath = [resourcesDir stringByAppendingPathComponent:@"Info-gnustep.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *iconFile = nil;
    if (plist != nil) {
        iconFile = [plist objectForKey:@"NSIcon"];
        if (iconFile == nil) iconFile = [plist objectForKey:@"CFBundleIconFile"];
    }
    NSString *srcPath = nil;
    if (iconFile != nil)
        srcPath = [resourcesDir stringByAppendingPathComponent:iconFile];
    if (srcPath == nil || ![fm fileExistsAtPath:srcPath]) {
        NSLog(@"make_appimage: no icon file (%@) in bundle resources", iconFile ?: @"unknown");
        return nil;
    }
    NSString *dstPath = [appDirPath stringByAppendingPathComponent:
        [desktopIcon stringByAppendingPathExtension:@"png"]];
    NSString *ext = [[srcPath pathExtension] lowercaseString];
    BOOL converted = NO;
    if ([ext isEqualToString:@"png"]) {
        NSError *err = nil;
        converted = [fm copyItemAtPath:srcPath toPath:dstPath error:&err];
    } else {
        NSString *convertTool = [self.class _findTool:@"convert"];
        if (convertTool) {
            // Take the largest frame of a multi-frame source and normalize to
            // an RGBA PNG; appimagetool requires a raster icon in the AppDir.
            converted = [self _runTool:convertTool withArgs:@[
                [srcPath stringByAppendingString:@"[0]"],
                dstPath]] != nil;
        }
    }
    if (converted) {
        NSLog(@"make_appimage: installed icon %@", dstPath);
        return desktopIcon;
    }
    NSLog(@"make_appimage: failed to convert icon %@", srcPath);
    return nil;
}

- (BOOL)package
{
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
        NSString *iconName = [self _installIconForDesktopIcon:appBasename inDir:appDirPath];
        if (iconName == nil) {
            NSLog(@"make_appimage: no application icon available; cannot package AppImage");
            return NO;
        }
        NSString *desktopContent = [NSString stringWithFormat:
            @"[Desktop Entry]\nType=Application\nName=%@\nComment=%@\nExec=%@\nIcon=%@\nCategories=%@\nTerminal=false\n",
            appBasename, comment ?: @"", mainExec, iconName,
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
        NSString *unamePath = [self.class _findTool:@"uname"];
        if (unamePath) {
            arch = [self _runTool:unamePath withArgs:@[@"-m"]];
            os = [self _runTool:unamePath withArgs:@[@"-s"]];
        }
        NSString *osLower = os ? [os lowercaseString] : @"linux";
        _outputFile = [NSString stringWithFormat:@"%@-%@-%@.AppImage",
                       appName, arch ?: @"unknown", osLower];
    }

    // Run appimagetool
    NSString *appimageToolPath = [self.class _findTool:_appimageTool];
    if (appimageToolPath) {
        if (![self _runTool:appimageToolPath withArgs:@[appDirPath, _outputFile]]) {
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
