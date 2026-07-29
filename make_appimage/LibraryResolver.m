/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "LibraryResolver.h"

@interface LibraryResolver ()
{
    NSMutableArray *_seenDeps;
    NSArray *_excludedLibraries;
    BOOL _verbose;
    BOOL _standalone;
    NSString *_lddPath;
    NSString *_patchelfPath;
}

- (NSString *)_findTool:(NSString *)name;
@end

static BOOL isELF(NSString *path)
{
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *magic = [fh readDataOfLength:4];
    [fh closeFile];
    if ([magic length] < 4) return NO;
    const unsigned char *bytes = [magic bytes];
    return (bytes[0] == 0x7f && bytes[1] == 'E' && bytes[2] == 'L' && bytes[3] == 'F');
}

static NSString *lastPathComponent(NSString *path)
{
    return [path lastPathComponent];
}

@implementation LibraryResolver

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

- (void)setVerbose:(BOOL)flag { _verbose = flag; }
- (void)setStandalone:(BOOL)flag { _standalone = flag; }

- (instancetype)initWithAppDir:(NSString *)appDirPath
{
    self = [super init];
    if (self) {
        _appDirPath = [appDirPath copy];
        _libraryLocations = [[NSMutableArray alloc] init];
        _seenDeps = [[NSMutableArray alloc] init];
        _lddPath = [self _findTool:@"ldd"];
        _patchelfPath = [self _findTool:@"patchelf"];

        _excludedLibraries = @[
            @"ld-linux.so.2",
            @"ld-linux-x86-64.so.2",
            @"ld-musl-x86_64.so.1",
            @"ld-musl-aarch64.so.1",
            @"ld-musl-armhf.so.1",
            @"ld-musl-i386.so.1",
            @"libanl.so.1",
            @"libBrokenLocale.so.1",
            @"libcidn.so.1",
            @"libc.so.6",
            @"libdl.so.2",
            @"libm.so.6",
            @"libmvec.so.1",
            @"libnss_compat.so.2",
            @"libnss_dns.so.2",
            @"libnss_files.so.2",
            @"libnss_hesiod.so.2",
            @"libnss_nisplus.so.2",
            @"libnss_nis.so.2",
            @"libpthread.so.0",
            @"libresolv.so.2",
            @"librt.so.1",
            @"libthread_db.so.1",
            @"libutil.so.1",
            @"libstdc++.so.6",
            @"libGL.so.1",
            @"libEGL.so.1",
            @"libGLdispatch.so.0",
            @"libGLX.so.0",
            @"libdrm.so.2",
            @"libglapi.so.0",
            @"libgbm.so.1",
            @"libxcb.so.1",
            @"libX11.so.6",
            @"libgio-2.0.so.0",
            @"libasound.so.2",
            @"libgdk_pixbuf-2.0.so.0",
            @"libfontconfig.so.1",
            @"libthai.so.0",
            @"libfreetype.so.6",
            @"libharfbuzz.so.0",
            @"libcom_err.so.2",
            @"libexpat.so.1",
            @"libgcc_s.so.1",
            @"libglib-2.0.so.0",
            @"libgpg-error.so.0",
            @"libICE.so.6",
            @"libp11-kit.so.0",
            @"libSM.so.6",
            @"libusb-1.0.so.0",
            @"libuuid.so.1",
            @"libz.so.1",
            @"libgobject-2.0.so.0",
            @"libpangoft2-1.0.so.0",
            @"libpangocairo-1.0.so.0",
            @"libpango-1.0.so.0",
            @"libjack.so.0",
            @"libxcb-dri3.so.0",
            @"libxcb-dri2.so.0",
            @"libfribidi.so.0",
            @"libgmp.so.10"
        ];
        if (_verbose) NSLog(@"LibraryResolver: Excluded %lu system libraries", (unsigned long)[_excludedLibraries count]);

        NSArray *defaultPaths = @[
            @"/usr/lib64", @"/lib64", @"/usr/lib", @"/lib",
            @"/usr/lib/x86_64-linux-gnu", @"/lib/x86_64-linux-gnu",
            @"/usr/local/lib", @"/usr/local/lib/x86_64-linux-gnu",
            @"/lib32", @"/usr/lib32"
        ];
        for (NSString *p in defaultPaths) {
            if (![_libraryLocations containsObject:p]) {
                [_libraryLocations addObject:p];
            }
        }
        if (_verbose) NSLog(@"LibraryResolver: Default library search paths: %lu", (unsigned long)[_libraryLocations count]);

        [self parseLdSoConf];

        NSString *ldLibraryPath = [[[NSProcessInfo processInfo] environment]
            objectForKey:@"LD_LIBRARY_PATH"];
        if ([ldLibraryPath length] > 0) {
            NSArray *paths = [ldLibraryPath componentsSeparatedByString:@":"];
            for (NSString *p in paths) {
                if ([p length] > 0 && ![_libraryLocations containsObject:p]) {
                    [_libraryLocations addObject:p];
                }
            }
            if (_verbose) NSLog(@"LibraryResolver: Added %lu paths from LD_LIBRARY_PATH", (unsigned long)[paths count]);
        }
        if (_verbose) NSLog(@"LibraryResolver: Total search paths: %lu", (unsigned long)[_libraryLocations count]);
    }
    return self;
}

- (NSArray *)libraryLocations
{
    return _libraryLocations;
}

- (BOOL)isExcludedLibrary:(NSString *)name
{
    if (_standalone) return NO;
    NSString *filename = lastPathComponent(name);
    return [_excludedLibraries containsObject:filename];
}

#pragma mark - ld.so.conf parsing

- (void)parseLdSoConf
{
    if (_verbose) NSLog(@"LibraryResolver: Parsing /etc/ld.so.conf...");
    [self parseLdSoConfAtPath:@"/etc/ld.so.conf"];
}

- (void)parseLdSoConfAtPath:(NSString *)path
{
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!content) {
        if (_verbose) NSLog(@"LibraryResolver: ld.so.conf not found at %@", path);
        return;
    }
    if (_verbose) NSLog(@"LibraryResolver: Parsing ld.so.conf: %@", path);

    NSString *baseDir = [path stringByDeletingLastPathComponent];
    NSArray *lines = [content componentsSeparatedByString:@"\n"];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed length] == 0 || [trimmed hasPrefix:@"#"]) continue;

        if ([trimmed hasPrefix:@"include "]) {
            NSString *pattern = [trimmed substringFromIndex:8];
            if ([pattern length] == 0) continue;
            if ([pattern characterAtIndex:0] != '/') {
                pattern = [baseDir stringByAppendingPathComponent:pattern];
            }
            NSArray *matched = [self globFiles:pattern];
            for (NSString *f in matched) {
                [self parseLdSoConfAtPath:f];
            }
        } else if ([trimmed hasPrefix:@"hwcap "]) {
            continue;
        } else {
            if (![_libraryLocations containsObject:trimmed]) {
                [_libraryLocations addObject:trimmed];
            }
        }
    }
}

- (NSArray *)globFiles:(NSString *)pattern
{
    NSMutableArray *result = [NSMutableArray array];
    NSString *dir = [pattern stringByDeletingLastPathComponent];
    NSString *glob = [pattern lastPathComponent];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:NULL];
    if (!entries) return result;

    for (NSString *entry in entries) {
        if ([self fnmatch:glob string:entry]) {
            [result addObject:[dir stringByAppendingPathComponent:entry]];
        }
    }
    return result;
}

- (BOOL)fnmatch:(NSString *)pattern string:(NSString *)str
{
    if ([pattern isEqualToString:@"*"]) return YES;
    if ([pattern isEqualToString:str]) return YES;
    if ([pattern hasPrefix:@"*"]) {
        NSString *suffix = [pattern substringFromIndex:1];
        return [str hasSuffix:suffix];
    }
    if ([pattern hasSuffix:@"*"]) {
        NSString *prefix = [pattern substringToIndex:[pattern length] - 1];
        return [str hasPrefix:prefix];
    }
    return [pattern isEqualToString:str];
}

#pragma mark - Find ELFs

- (NSArray *)findAllELFsInAppDir
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *results = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:_appDirPath];
    NSString *subpath;
    NSUInteger scanned = 0;

    while ((subpath = [enumerator nextObject])) {
        NSString *fullPath = [_appDirPath stringByAppendingPathComponent:subpath];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir]) continue;
        if (isDir) continue;

        if (!isELF(fullPath)) continue;
        scanned++;

        NSString *dirName = [subpath stringByDeletingLastPathComponent];
        if ([[dirName lastPathComponent] hasPrefix:@"lib"]) {
            NSString *fname = lastPathComponent(fullPath);
            BOOL alreadyKnown = NO;
            for (NSString *existing in results) {
                if ([[existing lastPathComponent] isEqualToString:fname]) {
                    alreadyKnown = YES;
                    break;
                }
            }
            if (alreadyKnown) {
                NSLog(@"LibraryResolver:   Skipping duplicate: %@", subpath);
                continue;
            }
        }

        [results addObject:fullPath];
    }
    NSLog(@"LibraryResolver: Scanned %lu ELF files in AppDir, found %lu unique",
          (unsigned long)scanned, (unsigned long)[results count]);
    return results;
}

#pragma mark - Dependency resolution

- (NSArray *)resolveDependenciesForExecutables:(NSArray *)executables
{
    NSLog(@"LibraryResolver: Resolving dependencies for %lu executables", (unsigned long)[executables count]);
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *exe in executables) {
        [self resolveDependenciesForPath:exe results:result];
    }
    NSLog(@"LibraryResolver: Resolved %lu unique library dependencies", (unsigned long)[result count]);
    return result;
}

- (void)resolveDependenciesForPath:(NSString *)path results:(NSMutableArray *)results
{
    if ([_seenDeps containsObject:path]) {
        if (_verbose) NSLog(@"LibraryResolver:   Already seen: %@ (circular ref)", [path lastPathComponent]);
        return;
    }
    [_seenDeps addObject:path];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSLog(@"LibraryResolver:   Path does not exist: %@", path);
        return;
    }

    NSLog(@"LibraryResolver:   Resolving deps for: %@", path);

    if (isELF(path)) {
        [self addRPathLocationsForPath:path];
    }

    if (!_lddPath) return;
    @try {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:_lddPath];
        [task setArguments:@[path]];

        NSPipe *outPipe = [NSPipe pipe];
        [task setStandardOutput:outPipe];
        [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

        [task launch];
        [task waitUntilExit];

        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:outData
                                                 encoding:NSUTF8StringEncoding];
        if (!output) return;

        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        NSUInteger depCount = 0;
        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];

            NSRange arrowRange = [trimmed rangeOfString:@" => "];
            if (arrowRange.location == NSNotFound) continue;

            NSString *libPathPart = [trimmed substringFromIndex:
                arrowRange.location + arrowRange.length];

            NSUInteger spacePos = [libPathPart rangeOfString:@" "].location;
            NSString *libPath;
            if (spacePos != NSNotFound) {
                libPath = [libPathPart substringToIndex:spacePos];
            } else {
                libPath = libPathPart;
            }

            if ([libPath length] == 0) continue;

            NSString *libName = lastPathComponent(libPath);
            if ([self isExcludedLibrary:libName]) {
                if (_verbose) NSLog(@"LibraryResolver:     Excluded: %@ (%@)", libName, libPath);
                continue;
            }

            if (![[NSFileManager defaultManager] fileExistsAtPath:libPath]) continue;

            if (![results containsObject:libPath]) {
                [results addObject:libPath];
                depCount++;
                if (_verbose) NSLog(@"LibraryResolver:     Dependency #%lu: %@", (unsigned long)depCount, libPath);
            }

            [self resolveDependenciesForPath:libPath results:results];
        }
        if (_verbose) NSLog(@"LibraryResolver:   %@ has %lu new dependencies", [path lastPathComponent], (unsigned long)depCount);
    } @catch (NSException *exception) {
        NSLog(@"LibraryResolver:   Exception running ldd on %@: %@", path, exception);
        return;
    }
}

- (void)addRPathLocationsForPath:(NSString *)path
{
    if (!_patchelfPath) return;
    @try {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:_patchelfPath];
        [task setArguments:@[@"--print-rpath", path]];

        NSPipe *outPipe = [NSPipe pipe];
        [task setStandardOutput:outPipe];
        [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

        [task launch];
        [task waitUntilExit];

        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        NSString *rpath = [[NSString alloc] initWithData:outData
                                                encoding:NSUTF8StringEncoding];
        if ([rpath length] == 0) return;

        rpath = [rpath stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([rpath length] == 0) return;

        NSLog(@"LibraryResolver:   RPATH of %@: %@", [path lastPathComponent], rpath);
        NSArray *paths = [rpath componentsSeparatedByString:@":"];
        for (NSString *p in paths) {
            if ([p length] > 0 && ![p hasPrefix:@"$ORIGIN"]
                && ![_libraryLocations containsObject:p]) {
                [_libraryLocations addObject:p];
                NSLog(@"LibraryResolver:     Added RPATH dir: %@", p);
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"LibraryResolver:   patchelf --print-rpath failed for %@: %@", path, exception);
    }
}

@end
