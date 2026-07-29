/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AppImageBuilder.h"

int
main(int argc, const char *argv[])
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
    BOOL standalone = YES;
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
        printf("Options:\n");
        printf("  -o <file>     Output AppImage filename\n");
        printf("  -d <dir>      Working directory for AppDir build (default: /tmp/appimage-<app>)\n");
        printf("  -c <comment>  Comment for .desktop file\n");
        printf("  -C <cat>      Categories for .desktop file (e.g. \"Utility;\")\n");
        printf("  -e <path>     Main executable relative to AppDir (auto-detected)\n");
        printf("  -t <tool>     Path to appimagetool (default: appimagetool in PATH)\n");
        printf("  -s            Standalone mode: bundle all libraries (default)\n");
        printf("  --no-standalone  Use exclusion list for system libs (smaller output)\n");
        printf("  -v, --verbose Verbose output\n");
        printf("  -h            Show help\n");
        return (appName == nil && !showHelp) ? 1 : 0;
    }

    AppImageBuilder *builder = [[AppImageBuilder alloc] initWithAppName:appName];

    if (outputFile != nil)
        [builder setOutputFile:outputFile];
    if (buildDir != nil)
        [builder setBuildDirectory:buildDir];
    if (comment != nil)
        [builder setComment:comment];
    if (categories != nil)
        [builder setCategories:categories];
    if (mainExec != nil)
        [builder setMainExecutable:mainExec];
    if (appimageTool != nil)
        [builder setAppimageTool:appimageTool];
    [builder setStandalone:standalone];
    [builder setVerbose:verbose];

    BOOL success = [builder build];

    return success ? 0 : 1;
    }
}
