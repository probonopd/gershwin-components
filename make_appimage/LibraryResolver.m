/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// LibraryResolver — resolves ELF shared library dependencies for an AppDir.
//
// Why ldd: Parsing ldd output is simpler and more portable than reimplementing
// ELF DT_NEEDED traversal. ldd handles cross-arch, musl, and glibc transparently.
// Why per-system paths: We parse /etc/ld.so.conf to discover all system-wide
// library search paths so ldd resolves correctly even on nonstandard layouts.
// Why exclusions: Core system libraries (libc.so.6, libm.so.6, libpthread.so.0,
// etc.) are expected on any host and inflate AppImage size if bundled.
// Why standalone disables them: --standalone means "truly self-contained" for
// hosts that might lack these libs (e.g., containers, musl-only systems).
// Why RPATH preservation: Bundled ELFs often use $ORIGIN/../Resources or
// similar app-relative RPATHs. Resolving them at deploy time ensures ldd
// finds sibling libs inside the AppDir tree.

#import "LibraryResolver.h"
#include <elf.h>

@interface LibraryResolver ()
{
    NSMutableArray *_seenDeps;
    NSArray *_excludedLibraries;
    BOOL _verbose;
    BOOL _standalone;
    NSString *_lddPath;
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

        // Exact-match exclusion list. These are glibc/musl internals, graphics
        // drivers, and other host-provided libraries that should not be bundled
        // in non-standalone mode — they are guaranteed on any desktop Linux or
        // pull in dozens of driver-specific variants that bloat the AppImage.
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

        // Derive GNUstep library paths from the environment so we adapt to
        // any installation layout (/Local, /System, /GNUstep, etc.) instead
        // of hardcoding.  Fall back to the standard layout when unset.
        NSString *sysRoot = [[[NSProcessInfo processInfo] environment]
            objectForKey:@"GNUSTEP_SYSTEM_ROOT"] ?: @"/System";
        NSString *locRoot = [[[NSProcessInfo processInfo] environment]
            objectForKey:@"GNUSTEP_LOCAL_ROOT"] ?: @"/Local";
        NSString *sysLibs = [sysRoot stringByAppendingPathComponent:@"Library/Libraries"];
        NSString *locLibs = [locRoot stringByAppendingPathComponent:@"Library/Libraries"];

        // Local first, then System, then standard paths.
        // This ensures the app's locally-built libraries (which the app was
        // compiled and linked against) take precedence over the system ones.
        NSArray *defaultPaths = @[
            locLibs, sysLibs,
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
    // Standalone mode: deploy everything, no exclusions.
    // The AppImage is meant to run on any Linux (even minimal containers),
    // so it must carry its own copy of every library.
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
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [queue setMaxConcurrentOperationCount:8];
    NSMutableSet *pending = [NSMutableSet set];

    for (NSString *exe in executables)
        [pending addObject:exe];

    while ([pending count] > 0) {
        NSArray *batch = [pending allObjects];
        [pending removeAllObjects];
        NSMutableArray *ops = [NSMutableArray array];
        NSMutableSet *batchSeen = [NSMutableSet set];

        for (NSString *path in batch) {
            if ([_seenDeps containsObject:path]) continue;
            [_seenDeps addObject:path];
            [batchSeen addObject:path];

            // RPATH parsing (fast, no subprocess)
            if (isELF(path)) {
                [self addRPathLocationsForPath:path];
            }

            // ldd in a parallel operation
            if (!_lddPath) continue;
            // Prepend known search paths so ldd finds GNUstep libraries
            // even when LD_LIBRARY_PATH is unset (e.g. under sudo).
            NSString *ldLibraryPathEnv = [_libraryLocations componentsJoinedByString:@":"];
            NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
                @autoreleasepool {
                    NSTask *task = [[NSTask alloc] init];
                    [task setLaunchPath:_lddPath];
                    [task setArguments:@[path]];
                    NSMutableDictionary *env = [NSMutableDictionary
                        dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
                    [env setObject:ldLibraryPathEnv forKey:@"LD_LIBRARY_PATH"];
                    [task setEnvironment:env];
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
                    __block NSUInteger depCount = 0;
                    for (NSString *line in lines) {
                        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
                        NSRange arrowRange = [trimmed rangeOfString:@" => "];
                        if (arrowRange.location == NSNotFound) continue;
                        NSString *libPathPart = [trimmed substringFromIndex:
                            arrowRange.location + arrowRange.length];
                        NSUInteger spacePos = [libPathPart rangeOfString:@" "].location;
                        NSString *libPath = (spacePos != NSNotFound)
                            ? [libPathPart substringToIndex:spacePos] : libPathPart;
                        if ([libPath length] == 0) continue;

                        NSString *libName = lastPathComponent(libPath);
                        if ([self isExcludedLibrary:libName]) return;

                        if (![[NSFileManager defaultManager] fileExistsAtPath:libPath]) return;

                        @synchronized(result) {
                            if (![result containsObject:libPath]) {
                                [result addObject:libPath];
                                depCount++;
                                if (![_seenDeps containsObject:libPath])
                                    [pending addObject:libPath];
                            }
                        }
                    }
                    if (_verbose) {
                        @synchronized(self) {
                            NSLog(@"LibraryResolver:   %@ has %lu deps",
                                  [path lastPathComponent], (unsigned long)depCount);
                        }
                    }
                }
            }];
            [ops addObject:op];
        }

        if ([ops count] > 0) {
            [queue addOperations:ops waitUntilFinished:YES];
        }
    }

    NSLog(@"LibraryResolver: Resolved %lu unique library dependencies", (unsigned long)[result count]);
    return result;
}

// Extract RPATH/RUNPATH from an ELF by parsing its PT_DYNAMIC directly.
// This avoids spawning patchelf for every library (the main bottleneck).
- (void)addRPathLocationsForPath:(NSString *)path
{
    const char *cpath = [path UTF8String];
    FILE *f = fopen(cpath, "rb");
    if (!f) return;

    // Read ELF header
    Elf64_Ehdr ehdr;
    if (fread(&ehdr, 1, sizeof(ehdr), f) != sizeof(ehdr)
        || memcmp(ehdr.e_ident, "\177ELF", 4) != 0
        || ehdr.e_ident[EI_CLASS] != ELFCLASS64)
        { fclose(f); return; }

    // Read program headers
    Elf64_Phdr phdr[64];
    if (ehdr.e_phnum > 64 || ehdr.e_phentsize != sizeof(Elf64_Phdr))
        { fclose(f); return; }
    fseek(f, ehdr.e_phoff, SEEK_SET);
    if (fread(phdr, 1, ehdr.e_phnum * sizeof(Elf64_Phdr), f)
        != ehdr.e_phnum * sizeof(Elf64_Phdr))
        { fclose(f); return; }

    // Find PT_DYNAMIC and PT_LOAD for the dynamic segment
    Elf64_Addr dyn_vaddr = 0; size_t dyn_size = 0;
    unsigned long file_bias = 0; /* delta between vaddr and file offset */
    for (int i = 0; i < ehdr.e_phnum; i++) {
        if (phdr[i].p_type == PT_LOAD && phdr[i].p_vaddr == 0)
            file_bias = phdr[i].p_offset; /* usually 0 */
        if (phdr[i].p_type == PT_DYNAMIC) {
            dyn_vaddr = phdr[i].p_vaddr;
            dyn_size = phdr[i].p_memsz;
        }
    }
    if (!dyn_vaddr || !dyn_size) { fclose(f); return; }

    // Read dynamic section
    unsigned long dyn_file_off = dyn_vaddr - (file_bias ? 0 : 0);
    // For PIE binaries loaded at vaddr, offset = dyn_vaddr (since vaddr == file offset)
    // Fallback: compute from first PT_LOAD
    for (int i = 0; i < ehdr.e_phnum; i++) {
        if (phdr[i].p_type == PT_LOAD && dyn_vaddr >= phdr[i].p_vaddr
            && dyn_vaddr < phdr[i].p_vaddr + phdr[i].p_filesz) {
            dyn_file_off = phdr[i].p_offset + (dyn_vaddr - phdr[i].p_vaddr);
            break;
        }
    }

    Elf64_Dyn *dyn = malloc(dyn_size);
    if (!dyn) { fclose(f); return; }
    fseek(f, dyn_file_off, SEEK_SET);
    if (fread(dyn, 1, dyn_size, f) != dyn_size) { free(dyn); fclose(f); return; }
    int ndyn = dyn_size / sizeof(Elf64_Dyn);

    // Scan for DT_STRTAB (to locate .dynstr) and DT_RPATH/DT_RUNPATH
    Elf64_Addr strtab_vaddr = 0;
    Elf64_Addr rpath_str_offset = 0;
    BOOL has_rpath = NO;
    for (int i = 0; i < ndyn; i++) {
        if (dyn[i].d_tag == DT_STRTAB) strtab_vaddr = dyn[i].d_un.d_ptr;
        if (dyn[i].d_tag == DT_RPATH || dyn[i].d_tag == DT_RUNPATH) {
            rpath_str_offset = dyn[i].d_un.d_val;
            has_rpath = YES;
        }
    }

    if (has_rpath && strtab_vaddr && rpath_str_offset) {
        // Read .dynstr to find the RPATH string
        unsigned long strtab_file_off = 0;
        for (int i = 0; i < ehdr.e_phnum; i++) {
            if (phdr[i].p_type == PT_LOAD && strtab_vaddr >= phdr[i].p_vaddr
                && strtab_vaddr < phdr[i].p_vaddr + phdr[i].p_filesz) {
                strtab_file_off = phdr[i].p_offset + (strtab_vaddr - phdr[i].p_vaddr);
                break;
            }
        }

        if (strtab_file_off) {
            // Read the RPATH string from .dynstr
            fseek(f, strtab_file_off + rpath_str_offset, SEEK_SET);
            char buf[4096];
            if (fgets(buf, sizeof(buf), f)) {
                NSString *rpath = [NSString stringWithUTF8String:buf];
                if ([rpath length] > 0) {
                    if (_verbose)
                        NSLog(@"LibraryResolver:   RPATH of %@: %@",
                              [path lastPathComponent], rpath);
                    NSArray *paths = [rpath componentsSeparatedByString:@":"];
                    for (NSString *p in paths) {
                        if ([p length] > 0 && ![p hasPrefix:@"$ORIGIN"]
                            && ![_libraryLocations containsObject:p]) {
                            [_libraryLocations addObject:p];
                            if (_verbose)
                                NSLog(@"LibraryResolver:     Added RPATH dir: %@", p);
                        }
                    }
                }
            }
        }
    }

    free(dyn);
    fclose(f);
}

@end
