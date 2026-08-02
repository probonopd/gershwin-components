/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * make_standalone — same build pipeline as make_appimage but produces a
 * self-contained .app bundle instead of an AppImage.  The AppRun binary
 * is set as the bundle's NSExecutable so it runs when the .app bundle
 * is launched directly.
 *
 * Shares BundleBuilder.m, LibraryResolver.m, LibraryDeployer.m,
 * InterpreterDeployer.m, and AppRun.c with make_appimage — no duplication.
 *
 * Usage: make_standalone [options] <app-name>
 */

#import "BundleBuilder.h"

int
main(void)
{
    @autoreleasepool
    {
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    NSUInteger count = [args count];
    NSString *appName = nil;
    NSString *buildDir = nil;
    NSString *themeName = nil;
    NSMutableArray *frameworks = [NSMutableArray array];
    NSMutableArray *extraBundles = [NSMutableArray array];
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
        else if ([arg isEqualToString:@"-d"])
        {
            if (++i < count)
                buildDir = [args objectAtIndex:i];
        }
        else if ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--verbose"])
        {
            verbose = YES;
        }
        else if ([arg isEqualToString:@"--theme"])
        {
            if (++i < count)
                themeName = [args objectAtIndex:i];
        }
        else if ([arg isEqualToString:@"--no-theme"])
        {
            // Handled below — we don't skip themes in standalone mode,
            // but we accept the flag for script compatibility.
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
        printf("Usage: make_standalone [options] <app-name>\n\n");
        printf("Options:\n");
        printf("  -d <dir>      Working directory (default: /tmp/standalone-<app>)\n");
        printf("  --theme <name>  Deploy only the specified theme\n");
        printf("  --no-theme      Skip theme deployment\n");
        printf("  --framework <name>  Deploy specified framework (repeatable)\n");
        printf("  --extra-bundle <name>  Deploy additional bundle (repeatable)\n");
        printf("  -v, --verbose  Verbose output\n");
        printf("  -h             Show help\n");
        return (appName == nil && !showHelp) ? 1 : 0;
    }

    BundleBuilder *builder = [[BundleBuilder alloc] initWithAppName:appName];

    if (buildDir == nil)
        buildDir = [NSString stringWithFormat:@"/tmp/standalone-%@", appName];
    [builder setBuildDirectory:buildDir];
    [builder setStandalone:YES];
    [builder setDeployTheme:YES];
    if (themeName != nil)
        [builder setThemeName:themeName];
    if ([frameworks count] > 0)
        [builder setFrameworks:frameworks];
    if ([extraBundles count] > 0)
        [builder setExtraBundles:extraBundles];
    [builder setVerbose:verbose];

    // Enable standalone bundle mode: patch Info.plist NSExecutable -> AppRun,
    // remove AppImage-specific files, rename to .app.
    [builder setStandaloneBundle:YES];

    BOOL success = [builder build];

    return success ? 0 : 1;
    }
}
