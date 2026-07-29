/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

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
        // Check whether this is a musl-based system (Alpine, etc.)
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
    NSString *binDir = [_appDirPath stringByAppendingPathComponent:@"usr/bin"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:binDir error:NULL];
    if (!entries) return nil;

    // Search also inside .app bundles
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *entry in entries) {
        NSString *fullPath = [binDir stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir]) continue;
        if (isDir) {
            NSString *bundleExec = [fullPath stringByAppendingPathComponent:
                [entry stringByDeletingPathExtension]];
            if ([fm isExecutableFileAtPath:bundleExec]) {
                [candidates addObject:bundleExec];
            }
        } else {
            [candidates addObject:fullPath];
        }
    }

    // Also scan Local/Applications and similar
    for (NSString *sub in @[@"Local/Applications", @"System/Applications", @"usr/local/bin"]) {
        NSString *dir = [_appDirPath stringByAppendingPathComponent:sub];
        NSArray *subEntries = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *entry in subEntries) {
            NSString *full = [dir stringByAppendingPathComponent:entry];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir && [[entry pathExtension] isEqualToString:@"app"]) {
                NSString *exec = [full stringByAppendingPathComponent:[entry stringByDeletingPathExtension]];
                if ([fm isExecutableFileAtPath:exec])
                    [candidates addObject:exec];
            } else if (!isDir) {
                [candidates addObject:full];
            }
        }
    }

    // Also search for musl interpreters in standard locations
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
    NSString *targetPath = [_appDirPath stringByAppendingPathComponent:interpreterPath];

    if ([fm fileExistsAtPath:targetPath]) {
        [fm removeItemAtPath:targetPath error:NULL];
    }

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
