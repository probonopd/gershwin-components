/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GWBuildPreflight.h"
#import <ctype.h>
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
        // Group 1 is the opening delimiter ('<' or '"'); group 2 is the header
        // name.  The delimiter distinguishes system/external includes
        // ('<...>', which the package manager can provide) from project-local
        // includes ('"..."', which the project's own build resolves).
        regex = [NSRegularExpression regularExpressionWithPattern:
            @"#[ \\t]*(?:include|import)[ \\t]*([<\"])([^>\"]+)[>\"]"
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
    // entries for them (Foundation.h etc. are not distro packages).  Match by
    // top-level directory so the whole GNUstep* family is covered
    // (GNUstepGUI/, GNUstepBase/, ...), not just the bare GNUstep/ prefix.
    NSString *firstComponent = [[header componentsSeparatedByString:@"/"] firstObject];
    if ([firstComponent isEqualToString:@"AppKit"]
        || [firstComponent isEqualToString:@"Foundation"]
        || [firstComponent isEqualToString:@"Cocoa"]
        || [firstComponent isEqualToString:@"gnustep"]
        || [firstComponent hasPrefix:@"GNUstep"]) {
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

        // Preprocessor / comment state for this file, so dead-code imports
        // (commented out or behind a disabled #if) are not treated as missing.
        NSSet *undefined = [self _undefinedPlatformMacros];
        NSMutableArray *actives = [NSMutableArray array];
        NSMutableArray *inBlocks = [NSMutableArray array];
        NSMutableArray *lineRanges = [NSMutableArray array];
        [self _scanContent:content undefined:undefined
                lineActives:actives inBlockStarts:inBlocks ranges:lineRanges];

        for (NSTextCheckingResult *match in matches) {
            NSRange nameRange = [match rangeAtIndex:2];
            if (nameRange.location == NSNotFound) continue;
            NSString *header = [content substringWithRange:nameRange];

            // Quoted includes ('"..."') are project-local by convention: the
            // build resolves them relative to the project, so they can never
            // be installable system packages.  A missing one (e.g. an unused or
            // orphaned source file) must therefore not block the build.
            BOOL quoted = NO;
            NSRange delimRange = [match rangeAtIndex:1];
            if (delimRange.location != NSNotFound)
                quoted = [[content substringWithRange:delimRange] isEqualToString:@"\""];

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

            // A commented-out or platform-disabled import is never compiled;
            // do not let it block the build.
            if ([self _shouldSkipHeaderAtMatch:match inContent:content
                                      actives:actives inBlocks:inBlocks ranges:lineRanges]) {
                continue;
            }

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
                // A quoted (project-local) include that we cannot resolve is
                // the project's own concern, not an installable package, so it
                // must not abort the build.  Only genuinely external angle-bracket
                // ('<>') includes are hard failures.
                if (quoted) {
                    [self outputLine:[NSString stringWithFormat:
                        @"Preflight: skipping unresolved quoted include %@ "
                        "(project-local)", header]];
                    continue;
                }
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

#pragma mark - Preprocessor / comment awareness

// Macros that are known to be UNDEFINED on the Gershwin host (GNUstep on
// Linux/BSD).  A header guarded by such a macro (e.g. `#ifdef __MINGW32__`)
// is never compiled here, so it must not be treated as a missing dependency.
// Any macro NOT in this set is assumed defined, so we never accidentally skip
// a header that genuinely is included on this platform.
- (NSSet *)_undefinedPlatformMacros
{
    static NSSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"__MINGW32__", @"__MINGW64__", @"_M_IX86", @"_M_X64",
            @"_WIN32", @"_WIN64", @"WIN32", @"_WIN32_WINNT", @"__WIN32__",
            @"_MSC_VER", @"__MSC_VER", @"__CYGWIN__", @"__CYGWIN32__",
            @"TARGET_OS_WIN32", @"TARGET_OS_MAC", @"__APPLE__", @"__APPLE_CC__",
            @"TARGET_IPHONE_SIMULATOR",
        ]];
    });
    return set;
}

// Evaluate a `#if`/`#elif` expression.  Unsupported constructs fall back to
// "true" so we never skip a header that might actually be required.
- (BOOL)_evaluateIfExpression:(NSString *)expr undefined:(NSSet *)undefined
{
    if ([expr length] == 0) return YES;

    NSMutableArray *tokens = [NSMutableArray array];
    NSUInteger i = 0, n = [expr length];
    while (i < n) {
        unichar c = [expr characterAtIndex:i];
        if (isspace((int)c)) { i++; continue; }
        if (c == '(' || c == ')' || c == '!') {
            [tokens addObject:[NSString stringWithFormat:@"%C", c]];
            i++; continue;
        }
        if (c == '&' && i + 1 < n && [expr characterAtIndex:i + 1] == '&') {
            [tokens addObject:@"&&"]; i += 2; continue;
        }
        if (c == '|' && i + 1 < n && [expr characterAtIndex:i + 1] == '|') {
            [tokens addObject:@"||"]; i += 2; continue;
        }
        if (isalpha((int)c) || c == '_') {
            NSUInteger j = i;
            while (j < n && (isalnum((int)[expr characterAtIndex:j]) || [expr characterAtIndex:j] == '_')) j++;
            [tokens addObject:[expr substringWithRange:NSMakeRange(i, j - i)]];
            i = j; continue;
        }
        if (isdigit((int)c)) {
            NSUInteger j = i;
            while (j < n && isdigit((int)[expr characterAtIndex:j])) j++;
            [tokens addObject:[expr substringWithRange:NSMakeRange(i, j - i)]];
            i = j; continue;
        }
        // Unrecognized operator: bail out conservatively.
        return YES;
    }
    if ([tokens count] == 0) return YES;

    __block NSInteger pos = 0;
    __block BOOL (^parseOr)(void);
    __block BOOL (^parseAnd)(void);
    __block BOOL (^parseUnary)(void);
    __block BOOL (^parsePrimary)(void);

    parsePrimary = ^BOOL(void) {
        if (pos >= (NSInteger)[tokens count]) return YES;
        NSString *tok = tokens[pos];
        if ([tok isEqualToString:@"("]) {
            pos++;
            BOOL v = parseOr();
            if (pos < (NSInteger)[tokens count] && [tokens[pos] isEqualToString:@")"]) pos++;
            return v;
        }
        if ([tok isEqualToString:@"defined"]) {
            pos++;
            BOOL hasParen = NO;
            if (pos < (NSInteger)[tokens count] && [tokens[pos] isEqualToString:@"("]) {
                hasParen = YES; pos++;
            }
            NSString *m = (pos < (NSInteger)[tokens count]) ? tokens[pos] : @"";
            pos++;
            if (hasParen && pos < (NSInteger)[tokens count] && [tokens[pos] isEqualToString:@")"]) pos++;
            return ![undefined containsObject:m];
        }
        pos++;
        if ([tok isEqualToString:@"0"]) return NO;
        if ([tok isEqualToString:@"1"]) return YES;
        // Unknown identifier (a build-time macro): assume defined.
        return YES;
    };
    parseUnary = ^BOOL(void) {
        if (pos < (NSInteger)[tokens count] && [tokens[pos] isEqualToString:@"!"]) {
            pos++;
            return !parseUnary();
        }
        return parsePrimary();
    };
    parseAnd = ^BOOL(void) {
        BOOL v = parseUnary();
        while (pos < (NSInteger)[tokens count] && [tokens[pos] isEqualToString:@"&&"]) {
            pos++;
            v = v && parseUnary();
        }
        return v;
    };
    parseOr = ^BOOL(void) {
        BOOL v = parseAnd();
        while (pos < (NSInteger)[tokens count] && [tokens[pos] isEqualToString:@"||"]) {
            pos++;
            v = v || parseAnd();
        }
        return v;
    };
    return parseOr();
}

// Update the conditional stack for one preprocessor directive line (the leading
// '#' already stripped).  Stack entries are @[taken, active].
- (void)_applyDirective:(NSString *)directive
                toStack:(NSMutableArray *)stack
              undefined:(NSSet *)undefined
{
    NSString *body = [[directive substringFromIndex:1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSUInteger wordEnd = [body length];
    NSRange space = [body rangeOfString:@" "];
    NSRange paren = [body rangeOfString:@"("];
    if (space.location != NSNotFound) wordEnd = MIN(wordEnd, space.location);
    if (paren.location != NSNotFound) wordEnd = MIN(wordEnd, paren.location);
    NSString *word = [[body substringToIndex:wordEnd] lowercaseString];
    NSString *rest = [[body substringFromIndex:wordEnd]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([word isEqualToString:@"endif"]) {
        if ([stack count] > 0) [stack removeLastObject];
        return;
    }
    if ([word isEqualToString:@"else"]) {
        if ([stack count] > 0) {
            NSMutableArray *top = [stack lastObject];
            top[1] = @(![top[0] boolValue]);
            top[0] = @YES;
        }
        return;
    }

    BOOL cond = YES;
    if ([word isEqualToString:@"ifdef"] || [word isEqualToString:@"ifndef"]) {
        NSString *m = [rest stringByReplacingOccurrencesOfString:@"(" withString:@""];
        m = [m stringByReplacingOccurrencesOfString:@")" withString:@""];
        m = [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        cond = [word isEqualToString:@"ifdef"] ? ![undefined containsObject:m]
                                              : [undefined containsObject:m];
    } else if ([word isEqualToString:@"if"] || [word isEqualToString:@"elif"]) {
        cond = [self _evaluateIfExpression:rest undefined:undefined];
    } else {
        return; // not a conditional directive
    }

    if ([word isEqualToString:@"elif"]) {
        if ([stack count] > 0) {
            NSMutableArray *top = [stack lastObject];
            if ([top[0] boolValue]) {
                top[1] = @NO;
            } else {
                top[1] = @(cond);
                top[0] = @(cond);
            }
        }
    } else {
        [stack addObject:[NSMutableArray arrayWithObjects:@(cond), @(cond), nil]];
    }
}

// Precompute, per source line, whether it is compiled (all enclosing
// conditionals active) and whether it begins inside a block comment.
- (void)_scanContent:(NSString *)content
           undefined:(NSSet *)undefined
        lineActives:(NSMutableArray *)actives
      inBlockStarts:(NSMutableArray *)inBlocks
             ranges:(NSMutableArray *)ranges
{
    NSUInteger len = [content length];
    NSUInteger i = 0;
    BOOL inBlock = NO;
    NSMutableArray *stack = [NSMutableArray array];

    while (i < len) {
        NSRange nl = [content rangeOfString:@"\n"
                                    options:0
                                      range:NSMakeRange(i, len - i)];
        NSUInteger lineEnd = (nl.location == NSNotFound) ? len : nl.location;
        NSRange lineRange = NSMakeRange(i, lineEnd - i);
        [ranges addObject:[NSValue valueWithRange:lineRange]];
        [inBlocks addObject:@(inBlock)];

        NSString *line = [content substringWithRange:lineRange];
        NSMutableString *clean = [NSMutableString string];
        for (NSUInteger j = 0; j < [line length]; j++) {
            unichar c = [line characterAtIndex:j];
            if (inBlock) {
                if (c == '*' && j + 1 < [line length] && [line characterAtIndex:j + 1] == '/') {
                    inBlock = NO; j++;
                }
                continue;
            }
            if (c == '/' && j + 1 < [line length] && [line characterAtIndex:j + 1] == '/') break;
            if (c == '/' && j + 1 < [line length] && [line characterAtIndex:j + 1] == '*') {
                inBlock = YES; j++; continue;
            }
            [clean appendFormat:@"%C", c];
        }

        NSString *trimmed = [clean stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed length] > 0 && [trimmed characterAtIndex:0] == '#') {
            [self _applyDirective:trimmed toStack:stack undefined:undefined];
        }

        BOOL active = YES;
        for (NSArray *st in stack) {
            if (![st[1] boolValue]) { active = NO; break; }
        }
        [actives addObject:@(active)];
        i = lineEnd + 1;
    }
}

// Decide whether a regex-matched import is dead code (commented out or inside a
// disabled preprocessor block) and therefore must not be treated as a missing
// dependency.  `match.range` must be the range of the leading '#'.
- (BOOL)_shouldSkipHeaderAtMatch:(NSTextCheckingResult *)match
                       inContent:(NSString *)content
                        actives:(NSArray *)actives
                       inBlocks:(NSArray *)inBlocks
                         ranges:(NSArray *)ranges
{
    NSUInteger loc = match.range.location;
    NSInteger idx = -1;
    for (NSInteger k = 0; k < (NSInteger)[ranges count]; k++) {
        NSRange r = [ranges[k] rangeValue];
        if (loc >= r.location && loc < r.location + r.length) { idx = k; break; }
    }
    if (idx < 0) return NO;
    if (![actives[idx] boolValue]) return YES;

    NSRange lineRange = [ranges[idx] rangeValue];
    NSString *line = [content substringWithRange:lineRange];
    NSUInteger offset = loc - lineRange.location;
    NSString *before = [line substringToIndex:offset];

    if ([before containsString:@"//"]) return YES;

    // Block comment that opened (and never closed) before this point.
    NSRange start = [before rangeOfString:@"/*"];
    if (start.location != NSNotFound) {
        NSRange end = [before rangeOfString:@"*/"
                                     options:0
                                       range:NSMakeRange(start.location,
                                                         [before length] - start.location)];
        if (end.location == NSNotFound) return YES;
    } else if ([inBlocks[idx] boolValue]) {
        return YES;
    }
    return NO;
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