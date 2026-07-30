/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// InterpreterDeployer — detects and deploys the ld-linux (or ld-musl)
// dynamic linker/interpreter into the AppDir.
//
// Why .app bundle search: GNUstep apps are often bundles (.app directories)
// whose executables live inside. We scan inside them to find the real binary.
// Why musl paths: Alpine Linux and other musl-based distros use ld-musl-*
// instead of ld-linux-*. We add standard musl paths so AppImages built on
// musl hosts work correctly on glibc hosts (and vice versa with the bundled
// interpreter).
// Why readlink -f: ld-linux is frequently a symlink (e.g., ld-linux-x86-64.so.2
// → ld-2.31.so). We resolve the chain to get the real file for copying.
// Why isMusl flag exists: musl does not ship gconv modules, locale data, or
// nsswitch in the same way as glibc. Downstream code checks this flag to
// skip deploying those.
// Why we DON'T binary-patch: Earlier versions patched /lib → /XXX in the
// interpreter binary to alter its default search path. This broke $ORIGIN-
// based RPATH evaluation because the patched paths are longer/shorter and
// shift offsets. Modern patchelf --set-interpreter and --set-rpath handle
// this correctly without binary patching.

#import "InterpreterDeployer.h"

@interface InterpreterDeployer ()
{
    BOOL _verbose;
    BOOL _isMusl;
    NSString *_patchelfPath;
    NSString *_readelfPath;
    NSString *_readlinkPath;
    NSString *_chmodPath;
}
- (NSString *)_findTool:(NSString *)name;
@end

@implementation InterpreterDeployer

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

- (instancetype)initWithAppDir:(NSString *)appDirPath
{
    self = [super init];
    if (self) {
        _appDirPath = [appDirPath copy];
        _patchelfPath = [self _findTool:@"patchelf"];
        _readelfPath = [self _findTool:@"readelf"];
        _readlinkPath = [self _findTool:@"readlink"];
        _chmodPath = [self _findTool:@"chmod"];
        // Detect musl by checking for known ld-musl paths. Used downstream to
        // skip glibc-specific content (gconv, nss) that does not exist on musl.
        _isMusl = ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/lib/ld-musl-x86_64.so.1"] ||
                   [[NSFileManager defaultManager] isExecutableFileAtPath:@"/lib/ld-musl-aarch64.so.1"] ||
                   [[NSFileManager defaultManager] isExecutableFileAtPath:@"/lib/ld-musl-armhf.so.1"] ||
                   [[NSFileManager defaultManager] isExecutableFileAtPath:@"/lib/ld-musl-i386.so.1"]);
    }
    return self;
}

- (BOOL)isMusl { return _isMusl; }

- (NSString *)detectInterpreter
{
    NSFileManager *fm = [NSFileManager defaultManager];

    // In the new layout, the .app bundle IS the AppDir.  The main executable
    // sits at the AppDir root (e.g. AppDir/Workspace).  Scan the root and
    // Resources/ for ELF binaries.
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *scanDir in @[_appDirPath,
         [_appDirPath stringByAppendingPathComponent:@"Resources"]]) {
        NSArray *entries = [fm contentsOfDirectoryAtPath:scanDir error:NULL];
        for (NSString *entry in entries) {
            NSString *full = [scanDir stringByAppendingPathComponent:entry];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;
            // Skip metadata files
            if ([entry isEqualToString:@"AppRun"] ||
                [entry hasSuffix:@".desktop"] ||
                [entry hasSuffix:@".plist"]) continue;
            [candidates addObject:full];
        }
    }

    // Also search for musl interpreters in standard locations.
    // This ensures AppImages built on Alpine can bundle ld-musl and then
    // run on glibc hosts (the bundled interpreter bridges the gap).
    NSArray *muslPaths = @[@"/lib/ld-musl-x86_64.so.1",
                           @"/usr/lib/ld-musl-x86_64.so.1",
                           @"/lib/ld-musl-aarch64.so.1",
                           @"/lib/ld-musl-armhf.so.1",
                           @"/lib/ld-musl-i386.so.1"];
    for (NSString *mp in muslPaths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:mp])
            [candidates addObject:mp];
    }

    for (NSString *fullPath in candidates) {
        if (_patchelfPath) {
            @try {
                NSTask *task = [[NSTask alloc] init];
                [task setLaunchPath:_patchelfPath];
                [task setArguments:@[@"--print-interpreter", fullPath]];
                NSPipe *outPipe = [NSPipe pipe];
                [task setStandardOutput:outPipe];
                [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
                [task launch];
                [task waitUntilExit];
                if ([task terminationStatus] == 0) {
                    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
                    NSString *result = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
                    result = [result stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if ([result length] > 0) return result;
                }
            } @catch (NSException *e) {}
        }

        if (_readelfPath) {
            @try {
                NSTask *task = [[NSTask alloc] init];
                [task setLaunchPath:_readelfPath];
                [task setArguments:@[@"-l", fullPath]];
                NSPipe *outPipe = [NSPipe pipe];
                [task setStandardOutput:outPipe];
                [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
                [task launch];
                [task waitUntilExit];
                if ([task terminationStatus] == 0) {
                    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
                    NSString *output = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
                    NSString *marker = @"Requesting program interpreter:";
                    NSRange r = [output rangeOfString:marker];
                    if (r.location != NSNotFound) {
                        NSString *after = [output substringFromIndex:r.location + r.length];
                        after = [after stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        NSRange bracket = [after rangeOfString:@"]"];
                        if (bracket.location != NSNotFound)
                            after = [after substringToIndex:bracket.location];
                        after = [after stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        if ([after length] > 0) return after;
                    }
                }
            } @catch (NSException *e) {}
        }
    }
    return nil;
}

- (BOOL)deployInterpreter:(NSString *)interpreterPath
{
    if ([interpreterPath length] == 0) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    // Deploy ld-linux to Resources/GNUstep/Library/Libraries/<basename>
    NSString *basename = [interpreterPath lastPathComponent];
    NSString *targetPath = [_appDirPath stringByAppendingPathComponent:
        [@"Resources/GNUstep/Library/Libraries" stringByAppendingPathComponent:basename]];

    if ([fm fileExistsAtPath:targetPath]) {
        [fm removeItemAtPath:targetPath error:NULL];
    }

    // Resolve symlinks with readlink -f. /lib64/ld-linux-x86-64.so.2 is
    // often a symlink to /lib/ld-2.31.so; copying the link target ensures
    // the deployed file is a real regular file, not a dangling symlink.
    NSString *realPath = interpreterPath;
    if (_readlinkPath) {
        @try {
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:_readlinkPath];
            [task setArguments:@[@"-f", interpreterPath]];
            NSPipe *pipe = [NSPipe pipe];
            [task setStandardOutput:pipe];
            [task launch];
            [task waitUntilExit];
            if ([task terminationStatus] == 0) {
                NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
                NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                result = [result stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([result length] > 0) realPath = result;
            }
        } @catch (NSException *e) {}
    }

    NSString *targetDir = [targetPath stringByDeletingLastPathComponent];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:targetDir withIntermediateDirectories:YES
                        attributes:nil error:&err]) {
        NSLog(@"InterpreterDeployer: mkdir %@ failed: %@", targetDir, err);
        return NO;
    }

    if (![fm copyItemAtPath:realPath toPath:targetPath error:&err]) {
        NSLog(@"InterpreterDeployer: cp %@ -> %@ failed: %@", realPath, targetPath, err);
        return NO;
    }

    if (_chmodPath) {
        @try {
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:_chmodPath];
            [task setArguments:@[@"0755", targetPath]];
            [task launch];
            [task waitUntilExit];
        } @catch (NSException *e) {}
    }

    return YES;
}

// NOT CURRENTLY CALLED. Binary-patching the interpreter (replacing /lib, /usr,
// /etc with neutral placeholders) was meant to redirect its internal search
// paths into the AppDir. However, changing path lengths shifts data offsets
// in the ELF, which can corrupt $ORIGIN-relative RPATH entries and break
// libraries that rely on them. Modern patchelf --set-rpath is preferred.
- (BOOL)patchInterpreter:(NSString *)deployedPath
{
    if (_verbose) NSLog(@"InterpreterDeployer: patching %@", deployedPath);
    NSError *err = nil;
    NSData *fileData = [NSData dataWithContentsOfFile:deployedPath options:0 error:&err];
    if (!fileData) {
        NSLog(@"InterpreterDeployer: read %@ failed: %@", deployedPath, err);
        return NO;
    }

    NSMutableData *data = [fileData mutableCopy];

    static const struct {
        const char *search;
        const char *replace;
        NSUInteger len;
    } tbl[] = {
        {"/lib", "/XXX", 4},
        {"/usr", "/xxx", 4},
        {"/etc", "/EEE", 4},
    };

    for (size_t i = 0; i < sizeof(tbl) / sizeof(tbl[0]); i++) {
        NSData *searchData = [NSData dataWithBytesNoCopy:(void *)tbl[i].search
                                                  length:tbl[i].len freeWhenDone:NO];
        NSData *replaceData = [NSData dataWithBytesNoCopy:(void *)tbl[i].replace
                                                   length:tbl[i].len freeWhenDone:NO];
        NSRange searchRange = NSMakeRange(0, [data length]);
        while (searchRange.location < [data length]) {
            NSRange found = [data rangeOfData:searchData options:0 range:searchRange];
            if (found.location == NSNotFound) break;
            [data replaceBytesInRange:found withBytes:[replaceData bytes] length:[replaceData length]];
            searchRange.location = found.location + [replaceData length];
            searchRange.length = [data length] - searchRange.location;
        }
    }

    if (![data writeToFile:deployedPath options:NSDataWritingAtomic error:&err]) {
        NSLog(@"InterpreterDeployer: write %@ failed: %@", deployedPath, err);
        return NO;
    }
    return YES;
}

@end
