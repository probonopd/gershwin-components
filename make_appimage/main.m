/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * make_appimage — takes an already-built .app bundle, deploys all GNUstep
 * dependencies into it (via BundleBuilder), then packages it as an AppImage
 * (via AppImagePackager).
 *
 * Shared code: BundleBuilder.m, LibraryResolver.m, LibraryDeployer.m,
 * InterpreterDeployer.m are also used by make_standalone.
 */

#import "BundleBuilder.h"
#import "AppImagePackager.h"

int
main(void)
{
    @autoreleasepool
    {
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    NSUInteger count = [args count];
    NSString *appName = nil;
    NSString *outputFile = nil;
    NSString *buildDir = nil;
    NSString *comment = nil;
    NSString *categories = nil;
    NSString *mainExec = nil;
    NSString *appimageTool = nil;
    NSString *themeName = nil;
    NSMutableArray *frameworks = [NSMutableArray array];
    NSMutableArray *extraBundles = [NSMutableArray array];
    BOOL standalone = YES;
    BOOL deployTheme = YES;
    BOOL verbose = NO;
    BOOL showHelp = NO;

    for (NSUInteger i = 1; i < count; i++)
    {
        NSString *arg = [args objectAtIndex:i];

        if ([arg isEqualToString:@"-h"])
        {
            showHelp = YES;
            break;
        }
        else if ([arg isEqualToString:@"-o"])
        {
            if (++i < count)
                outputFile = [args objectAtIndex:i];
        }
        else if ([arg isEqualToString:@"-d"])
        {
            if (++i < count)
                buildDir = [args objectAtIndex:i];
        }
        else if ([arg isEqualToString:@"-c"])
        {
            if (++i < count)
                comment = [args objectAtIndex:i];
        }
        else if ([arg isEqualToString:@"-C"])
        {
            if (++i < count)
                categories = [args objectAtIndex:i];
        }
        else if ([arg isEqualToString:@"-e"])
        {
            if (++i < count)
                mainExec = [args objectAtIndex:i];
        }
        else if ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--verbose"])
        {
            verbose = YES;
        }
        else if ([arg isEqualToString:@"-s"] || [arg isEqualToString:@"--standalone"])
        {
            standalone = YES;
        }
        else if ([arg isEqualToString:@"--no-standalone"])
        {
            standalone = NO;
        }
        else if ([arg isEqualToString:@"--theme"])
        {
            if (++i < count)
                themeName = [args objectAtIndex:i];
        }
        else if ([arg isEqualToString:@"--no-theme"])
        {
            deployTheme = NO;
        }
        else if ([arg isEqualToString:@"--framework"])
        {
            if (++i < count)
                [frameworks addObject:[args objectAtIndex:i]];
        }
        else if ([arg isEqualToString:@"--extra-bundle"])
        {
            if (++i < count)
                [extraBundles addObject:[args objectAtIndex:i]];
        }
        else if ([arg isEqualToString:@"-t"])
        {
            if (++i < count)
                appimageTool = [args objectAtIndex:i];
        }
        else if ([arg hasPrefix:@"-"])
        {
            fprintf(stderr, "Unknown option: %s\n", [arg UTF8String]);
            return 1;
        }
        else
        {
            appName = arg;
        }
    }

    if (showHelp || appName == nil)
    {
        printf("Usage: make_appimage [options] <app-name>\n\n");
        printf("Packs an already-built .app bundle into a self-contained AppImage.\n\n");
        printf("Options:\n");
        printf("  -o <file>     Output AppImage filename\n");
        printf("  -d <dir>      Working directory for AppDir build (default: /tmp/appimage-<app>)\n");
        printf("  -c <comment>  Comment for .desktop file\n");
        printf("  -C <cat>      Categories for .desktop file (e.g. \"Utility;\")\n");
        printf("  -e <path>     Main executable relative to AppDir (auto-detected)\n");
        printf("  -t <tool>     Path to appimagetool (default: appimagetool in PATH)\n");
        printf("  -s            Standalone mode: bundle all libraries (default)\n");
        printf("  --no-standalone  Use exclusion list for system libs (smaller output)\n");
        printf("  --theme <name>  Deploy only the specified theme\n");
        printf("  --no-theme      Skip theme deployment entirely\n");
        printf("  --framework <name>  Deploy specified framework (repeatable); if unset, auto-detect\n");
        printf("  --extra-bundle <name>  Deploy additional bundle (repeatable); e.g. ImageThumbnailer.thumb\n");
        printf("  -v, --verbose Verbose output\n");
        printf("  -h            Show help\n");
        return (appName == nil && !showHelp) ? 1 : 0;
    }

    // Require appimagetool on PATH up front so we fail fast instead of
    // spending minutes building an AppDir we can never turn into an AppImage.
    NSString *toolPath = appimageTool ?: @"appimagetool";
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:toolPath] == NO &&
        [AppImagePackager findAppImageTool] == NO)
    {
        fprintf(stderr, "make_appimage: appimagetool not found in PATH; install it or use -t <path>\n");
        return 1;
    }

    // Build the bundle (shared with make_standalone)
    BundleBuilder *builder = [[BundleBuilder alloc] initWithAppName:appName];

    if (buildDir != nil)
        [builder setBuildDirectory:buildDir];
    if (comment != nil)
        [builder setComment:comment];
    if (categories != nil)
        [builder setCategories:categories];
    if (mainExec != nil)
        [builder setMainExecutable:mainExec];
    [builder setStandalone:standalone];
    [builder setDeployTheme:deployTheme];
    if (themeName != nil)
        [builder setThemeName:themeName];
    if ([frameworks count] > 0)
        [builder setFrameworks:frameworks];
    if ([extraBundles count] > 0)
        [builder setExtraBundles:extraBundles];
    [builder setVerbose:verbose];

    BOOL success = [builder build];
    if (!success) return 1;

    // Package as AppImage (AppImage-specific, not used by make_standalone)
    AppImagePackager *packager = [[AppImagePackager alloc] initWithBuilder:builder];
    if (appimageTool != nil)
        [packager setAppimageTool:appimageTool];
    if (outputFile != nil)
        [packager setOutputFile:outputFile];
    return [packager package] ? 0 : 1;
    }
}
