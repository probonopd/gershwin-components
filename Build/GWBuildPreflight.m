/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GWBuildPreflight.h"
#import <AppKit/AppKit.h>
#import <PackageManager/GWPackageManager.h>
#import <PackageManager/GWHeaderDatabase.h>

// The framework's progress-handler protocol used to stream package-manager
// output to the caller's progress window / log.
@interface GWBuildPreflight () <GWInstallProgressHandler>
@end

static NSRegularExpression *GWHeaderRegex(void)
{
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
            @"#[ \\t]*(?:include|import)[ \\t]*[<\"]([^>\"]+)[>\"]"
                                                          options:0 error:NULL];
    });
    return regex;
}

static BOOL GWIsSourceFile(NSString *name)
{
    static NSSet *extensions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithObjects:
            @"c", @"cc", @"cpp", @"cxx", @"c++",
            @"m", @"mm",
            @"h", @"hh", @"hpp", @"hxx", @"h++",
            @"inc", @"inl", nil];
    });
    NSString *ext = [name pathExtension];
    return (ext && [extensions containsObject:[ext lowercaseString]]);
}

static BOOL GWShouldSkipDirectory(NSString *name)
{
    if ([name hasPrefix:@"."]) return YES;
    if ([name isEqualToString:@"obj"]) return YES;
    if ([name isEqualToString:@"Build"]) return YES;
    if ([name isEqualToString:@"GNUstepDependencies"]) return YES;
    if ([name hasSuffix:@".app"]) return YES;
    if ([name hasSuffix:@".bundle"]) return YES;
    if ([name hasSuffix:@".framework"]) return YES;
    return NO;
}

@implementation GWBuildPreflight
{
    NSString *_sourceRoot;
    NSString *_makefilePath;
    NSMutableArray<NSString *> *_pendingPackages;
    NSMutableArray<NSString *> *_resolvedHeaders;
    NSMutableArray<NSString *> *_unresolvedHeaders;
    NSMutableArray<NSString *> *_blockedHeaders;
    NSSet *_localFilenames;
    NSSet *_blacklist;
    GWPreflightProgressBlock _progress;
    GWPreflightOutputBlock _output;
    BOOL _installedPackages;
}

// Result of asking the user for consent to install packages.
typedef NS_ENUM(NSInteger, GWPreflightConsent) {
    GWPreflightConsentInstall,
    GWPreflightConsentSkip,
    GWPreflightConsentCancel,
};

@synthesize consoleMode = _consoleMode;
@synthesize installMissing = _installMissing;

- (instancetype)initWithSourceRoot:(NSString *)sourceRoot
                      makefilePath:(NSString *)makefilePath
{
    self = [super init];
    if (self) {
        _sourceRoot = [sourceRoot copy];
        _makefilePath = [makefilePath copy];
        _pendingPackages = [NSMutableArray array];
        _resolvedHeaders = [NSMutableArray array];
        _unresolvedHeaders = [NSMutableArray array];
        _blockedHeaders = [NSMutableArray array];
    }
    return self;
}

- (void)setBlacklist:(NSArray<NSString *> *)blacklist
{
    _blacklist = [NSSet setWithArray:blacklist ?: @[]];
}

- (NSArray<NSString *> *)blacklist
{
    return [_blacklist allObjects];
}

- (NSArray<NSString *> *)pendingPackages
{
    return [_pendingPackages copy];
}

- (NSArray<NSString *> *)unresolvedHeaders
{
    return [_unresolvedHeaders copy];
}

- (BOOL)installedPackages
{
    return _installedPackages;
}

- (NSArray<NSString *> *)blockedHeaders
{
    return [_blockedHeaders copy];
}

#pragma mark - Source collection

- (void)collectFilesInDirectory:(NSString *)dir
                    withSuffix:(NSString *)suffix
                       results:(NSMutableArray<NSString *> *)results
{
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    if (!contents) return;

    for (NSString *name in contents) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) continue;

        if (isDir) {
            if (GWShouldSkipDirectory(name)) continue;
            [self collectFilesInDirectory:path withSuffix:suffix results:results];
        } else if (GWIsSourceFile(name)) {
            [results addObject:path];
        }
    }
}

- (NSArray<NSString *> *)collectSourceFiles
{
    NSMutableArray *files = [NSMutableArray array];
    [self collectFilesInDirectory:_sourceRoot withSuffix:@"" results:files];
    return files;
}

// Every basename present in the project tree; a #include of one of these is
// a project-local header and must never be treated as a system header.
- (NSSet *)collectLocalFilenames
{
    NSMutableArray *files = [NSMutableArray array];
    [self collectFilesInDirectory:_sourceRoot withSuffix:@"" results:files];
    NSMutableSet *names = [NSMutableSet setWithCapacity:[files count]];
    for (NSString *path in files) {
        [names addObject:[path lastPathComponent]];
    }
    return names;
}

- (BOOL)isHeaderBlacklisted:(NSString *)header
{
    if ([_blacklist count] == 0) return NO;
    // Mirror BuildController's isItemBlacklisted: matching (case-insensitive,
    // prefix-based) so the preflight and the failure dialog agree.
    NSString *stem = [[[header lastPathComponent] lowercaseString]
        stringByDeletingPathExtension];
    for (NSString *blacklisted in _blacklist) {
        NSString *b = [blacklisted lowercaseString];
        if ([stem isEqualToString:b]) return YES;
        if ([stem hasPrefix:b]) return YES;
    }
    return NO;
}

#pragma mark - Resolution

// Directories where gnustep-make may live.  $GNUSTEP_MAKEFILES wins when set;
// the remaining paths cover the common layouts (/System Gershwin layout,
// traditional /usr/GNUstep, and the Debian /usr/share/GNUstep layout).
+ (NSArray<NSString *> *)gnustepMakeDirectories
{
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *env = [[[NSProcessInfo processInfo] environment]
        objectForKey:@"GNUSTEP_MAKEFILES"];
    if ([env length] > 0) [dirs addObject:env];
    [dirs addObjectsFromArray:@[
        @"/System/Library/Makefiles",
        @"/usr/GNUstep/System/Library/Makefiles",
        @"/usr/local/GNUstep/System/Library/Makefiles",
        @"/usr/share/GNUstep/Makefiles",
        @"/usr/local/share/GNUstep/Makefiles",
    ]];
    return dirs;
}

// Headers shipped with gnustep-make's TestFramework (the ObjectTesting
// unit-test framework used by many projects' test tools) live outside every
// distro include prefix and appear in no distro package database; they are
// present whenever gnustep-make is, so they must be treated as installed.
+ (BOOL)headerIsShippedWithGnustepMake:(NSString *)header
{
    static NSSet *shippedBasenames = nil;
    if (!shippedBasenames) {
        NSMutableSet *names = [NSMutableSet set];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *dir in [self gnustepMakeDirectories]) {
            NSString *testFramework = [dir stringByAppendingPathComponent:
                @"TestFramework"];
            for (NSString *name in [fm contentsOfDirectoryAtPath:testFramework
                                                           error:NULL]) {
                if ([name hasSuffix:@".h"]) [names addObject:name];
            }
        }
        shippedBasenames = [[names copy] retain]; // app-lifetime singleton
    }

    return [shippedBasenames containsObject:[header lastPathComponent]];
}

// Resolution order: a header is resolved from (1) the project's own git repo,
// (2) the GNUstep / system installation, and only as a last resort (3) the
// package manager.  Layer 1 is handled by collectLocalFilenames below (headers
// whose basename exists in the tree are never considered).  Layer 2 is this
// method: GNUstep/ObjC runtime headers and anything already installed on the
// system are left alone.  Layer 3 (the package database) only sees headers
// that made it past both.
- (BOOL)headerIsSystem:(NSString *)header
    database:(GWHeaderDatabase *)db
    distro:(NSString *)distro
{
    // GNUstep and ObjC runtime headers are never resolved to packages: they
    // come from the GNUstep system domain, and the database simply has no
    // entries for them (Foundation.h etc. are not distro packages).
    if ([header hasPrefix:@"GNUstep/"]
        || [header hasPrefix:@"AppKit/"]
        || [header hasPrefix:@"Foundation/"]
        || [header hasPrefix:@"Cocoa/"]
        || [header hasPrefix:@"gnustep/"]) {
        return NO;
    }

    // Anything already installed is fine; also covers AppKit/Foundation/objc
    // headers that shipped with the GNUstep installation.
    if ([db isHeaderInstalled:header distro:distro]) return NO;

    // Headers that come with gnustep-make itself (ObjectTesting TestFramework)
    // are outside every distro prefix and in no package database, but they are
    // on disk wherever gnustep-make is - never resolve them to packages.
    if ([[self class] headerIsShippedWithGnustepMake:header]) return NO;

    return YES;
}

// Extracts every header that is not project-local and not already installed,
// and resolves the packages that provide them.  Returns the distinct package
// names; unresolved headers are recorded for diagnostics but never fail the
// build.
- (NSArray<NSString *> *)resolveMissingPackagesInFiles:(NSArray<NSString *> *)files
    database:(GWHeaderDatabase *)db
    distro:(NSString *)distro
{
    NSSet *localFilenames = [self collectLocalFilenames];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableDictionary *packageByHeader = [NSMutableDictionary dictionary];

    for (NSString *path in files) {
        NSString *content = [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
        if (!content) continue;
        if (![content containsString:@"#"]) continue;

        NSArray *matches = [GWHeaderRegex() matchesInString:content
                                                     options:0
                                                       range:NSMakeRange(0, [content length])];
        for (NSTextCheckingResult *match in matches) {
            NSRange nameRange = [match rangeAtIndex:1];
            if (nameRange.location == NSNotFound) continue;
            NSString *header = [content substringWithRange:nameRange];

            // Strip a leading slash or "./" from angle includes.
            while ([header hasPrefix:@"/"] || [header hasPrefix:@"./"]) {
                header = [header substringFromIndex:1];
            }
            if ([header length] == 0) continue;

            NSString *basename = [header lastPathComponent];
            // Layer 1: the header belongs to the project's own tree (git
            // repo / source checkout); never treat it as a system header.
            if ([localFilenames containsObject:basename]) continue;
            if ([seen containsObject:header]) continue;
            [seen addObject:header];

            // Layer 2: GNUstep / system-installed headers need no package.
            if (![self headerIsSystem:header database:db distro:distro]) continue;

            // Blacklisted technologies are never offered for installation;
            // record them so the caller can suggest an alternative.
            if ([self isHeaderBlacklisted:header]) {
                if (![_blockedHeaders containsObject:header]) {
                    [_blockedHeaders addObject:header];
                }
                continue;
            }

            // Layer 3 (last resort): resolve via the package manager database.
            NSError *error = nil;
            NSString *package = [db packageForHeader:header distro:distro error:&error];
            if (error) {
                [self outputLine:[NSString stringWithFormat:
                    @"Preflight: could not look up %@: %@", header, [error localizedDescription]]];
                continue;
            }
            if (package) {
                packageByHeader[header] = package;
                if (![_resolvedHeaders containsObject:header])
                    [_resolvedHeaders addObject:header];
            } else {
                if (![_unresolvedHeaders containsObject:header])
                    [_unresolvedHeaders addObject:header];
            }
        }
    }

    NSMutableArray *packages = [[packageByHeader allValues] mutableCopy];
    [packages sortUsingSelector:@selector(compare:)];
    NSMutableOrderedSet *distinct = [NSMutableOrderedSet orderedSetWithArray:packages];
    return [distinct array];
}

#pragma mark - Output helpers

- (void)outputLine:(NSString *)line
{
    if (_output) _output(line);
}

#pragma mark - Consent

- (GWPreflightConsent)confirmInstallationOfPackages:(NSArray<NSString *> *)packages
{
    if (_installMissing) return GWPreflightConsentInstall;

    if (_consoleMode) {
        fprintf(stdout, "Build requires the following development packages:\n");
        for (NSString *p in packages) {
            fprintf(stdout, "  - %s\n", [p UTF8String]);
        }
        fprintf(stdout, "Install them now? [y/N] ");
        fflush(stdout);

        char buf[16] = {0};
        if (!fgets(buf, sizeof(buf), stdin)) return GWPreflightConsentCancel;
        char answer = buf[0];
        if (answer == 'y' || answer == 'Y') return GWPreflightConsentInstall;
        if (answer == 'c' || answer == 'C' || answer == 'q' || answer == 'Q')
            return GWPreflightConsentCancel;
        return GWPreflightConsentSkip; // N / default: skip installation
    }

    // GUI: NSAlert with Install (default), Skip, Cancel.
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Install required development packages?"];
    NSMutableString *info = [NSMutableString stringWithString:
        @"The build needs headers from these packages:\n\n"];
    for (NSString *p in packages) {
        [info appendFormat:@"    %@\n", p];
    }
    [info appendString:@"\nInstall them now?  Without them the build will likely fail."];
    [alert setInformativeText:info];
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Skip"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert setAlertStyle:NSInformationalAlertStyle];
    // Same icon as the progress window (the product being built), so both
    // dialogs agree on what is being built; fall back to the app icon.
    NSImage *icon = self.iconImage ?: [NSApp applicationIconImage];
    if (icon) [alert setIcon:icon];

    NSInteger result = [alert runModal];
    if (result == NSAlertSecondButtonReturn) return GWPreflightConsentSkip;
    if (result == NSAlertThirdButtonReturn) return GWPreflightConsentCancel;
    return GWPreflightConsentInstall;
}

#pragma mark - Verification

- (BOOL)verifyHeadersInstalled:(NSArray<NSString *> *)headers
    database:(GWHeaderDatabase *)db distro:(NSString *)distro
{
    BOOL ok = YES;
    for (NSString *h in headers) {
        if (![db isHeaderInstalled:h distro:distro]) {
            [self outputLine:[NSString stringWithFormat:
                @"Preflight: header still missing after install: %@", h]];
            ok = NO;
        }
    }
    return ok;
}

#pragma mark - Run

- (GWPreflightDecision)runWithProgress:(nullable GWPreflightProgressBlock)progress
                                output:(nullable GWPreflightOutputBlock)output
                                 error:(NSError **)error
{
    _output = output;
    _progress = progress;

    GWHeaderDatabase *db = [GWHeaderDatabase sharedDatabase];
    if (!db || ![db isOpen]) {
        if (error) {
            *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                         code:GWPackageManagerErrorDatabaseUnavailable
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"The package header database could not be opened."}];
        }
        return GWPreflightDecisionAbort;
    }

    NSString *distro = [db databaseDistroForCurrentOS];
    if (!distro) {
        // No database data for this OS family (e.g. OpenBSD): preflight is a
        // no-op and the build proceeds as before.
        [self outputLine:@"Preflight: no header database for this OS; skipping."];
        return GWPreflightDecisionProceed;
    }

    [self outputLine:@"Preflight: scanning sources for system headers…"];
    NSArray *files = [self collectSourceFiles];
    if ([files count] == 0) {
        [self outputLine:@"Preflight: no source files found; skipping."];
        return GWPreflightDecisionProceed;
    }

    NSArray *packages = [self resolveMissingPackagesInFiles:files
                                                   database:db distro:distro];
    if ([_blockedHeaders count] > 0) {
        [self outputLine:[NSString stringWithFormat:
            @"Preflight: these headers require unsupported technologies and "
            "will not be installed:\n    %@\n"
            "Consider using an alternative technology.",
            [_blockedHeaders componentsJoinedByString:@", "]]];
    }
    // A header we cannot install is a hard stop: there is no point launching a
    // build that will fail on it, and proceeding has crashed the app in the
    // past.  Tell the user exactly which header is missing so they can install
    // it first.
    if ([_unresolvedHeaders count] > 0) {
        NSString *missing = [_unresolvedHeaders componentsJoinedByString:@", "];
        [self outputLine:[NSString stringWithFormat:
            @"Preflight: %lu required header(s) are missing and have no "
            "installable package: %@",
            (unsigned long)[_unresolvedHeaders count], missing]];
        if (error) {
            *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                         code:GWPackageManagerErrorCommandFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    NSLocalizedString(@"The following header(s) are missing and must be installed before building: %@",
                                      @"Preflight error: missing headers"),
                    missing]}];
        }
        return GWPreflightDecisionAbort;
    }
    if ([packages count] == 0) {
        [self outputLine:@"Preflight: all headers available; nothing to install."];
        return GWPreflightDecisionProceed;
    }

    [_pendingPackages setArray:packages];

    [self outputLine:[NSString stringWithFormat:
        @"Preflight: %lu development package(s) needed.", (unsigned long)[packages count]]];

    GWPreflightConsent consent = [self confirmInstallationOfPackages:packages];
    if (consent == GWPreflightConsentCancel) {
        [self outputLine:@"Preflight: cancelled by user."];
        return GWPreflightDecisionAbort; // error left nil: user cancel
    }
    if (consent == GWPreflightConsentSkip) {
        [self outputLine:@"Preflight: packages not installed; the build will likely "
            "fail on missing headers."];
        return GWPreflightDecisionProceed;
    }

    GWPackageManager *pm = [GWPackageManager sharedManager];
    BOOL installed = [pm installPackages:packages
                          localFilePaths:@[]
                               progress:self
                                  error:error];
    if (!installed) {
        if (error && *error == nil) {
            *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                         code:GWPackageManagerErrorCommandFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Installation of required packages failed."}];
        }
        return GWPreflightDecisionAbort;
    }
    _installedPackages = YES;

    // Fail hard: the build must not run with headers we promised to provide.
    if (![self verifyHeadersInstalled:_resolvedHeaders
                             database:db distro:distro]) {
        if (error) {
            *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                         code:GWPackageManagerErrorCommandFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Installed packages did not provide the required headers."}];
        }
        return GWPreflightDecisionAbort;
    }

    [self outputLine:@"Preflight: required packages installed successfully."];
    return GWPreflightDecisionProceed;
}

- (void)installDidProgress:(float)progress message:(NSString *)message
{
    if (_progress) _progress(progress, message);
}

- (void)installDidOutputLine:(NSString *)line
{
    [self outputLine:line];
}

@end