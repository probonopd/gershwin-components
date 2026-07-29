/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "InterpreterDeployer.h"

@implementation InterpreterDeployer

- (instancetype)initWithAppDir:(NSString *)appDirPath
{
    self = [super init];
    if (self) {
        _appDirPath = [appDirPath copy];
    }
    return self;
}

- (NSString *)detectInterpreter
{
    NSString *binDir = [_appDirPath stringByAppendingPathComponent:@"usr/bin"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:binDir error:NULL];
    if (!entries) return nil;

    for (NSString *entry in entries) {
        NSString *fullPath = [binDir stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir]) continue;
        if (isDir) continue;

        @try {
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"/usr/bin/patchelf"];
            [task setArguments:@[@"--print-interpreter", fullPath]];

            NSPipe *outPipe = [NSPipe pipe];
            [task setStandardOutput:outPipe];
            [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

            [task launch];
            [task waitUntilExit];

            if ([task terminationStatus] == 0) {
                NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
                NSString *result = [[NSString alloc] initWithData:outData
                                                        encoding:NSUTF8StringEncoding];
                result = [result stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([result length] > 0) {
                    return result;
                }
            }
        } @catch (NSException *exception) {
        }

        @try {
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"/usr/bin/readelf"];
            [task setArguments:@[@"-l", fullPath]];

            NSPipe *outPipe = [NSPipe pipe];
            [task setStandardOutput:outPipe];
            [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

            [task launch];
            [task waitUntilExit];

            if ([task terminationStatus] == 0) {
                NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
                NSString *output = [[NSString alloc] initWithData:outData
                                                         encoding:NSUTF8StringEncoding];
                if ([output length] == 0) continue;

                NSString *marker = @"Requesting program interpreter:";
                NSRange markerRange = [output rangeOfString:marker];
                if (markerRange.location != NSNotFound) {
                    NSString *after = [output substringFromIndex:
                        markerRange.location + markerRange.length];
                    after = [after stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    NSRange bracketRange = [after rangeOfString:@"]"];
                    if (bracketRange.location != NSNotFound) {
                        after = [after substringToIndex:bracketRange.location];
                    }
                    after = [after stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if ([after length] > 0) {
                        return after;
                    }
                }
            }
        } @catch (NSException *exception) {
        }
    }
    return nil;
}

- (BOOL)deployInterpreter:(NSString *)interpreterPath
{
    if ([interpreterPath length] == 0) {
        NSLog(@"deployInterpreter: empty interpreter path");
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *targetPath = [_appDirPath stringByAppendingPathComponent:interpreterPath];

    if ([fm fileExistsAtPath:targetPath]) {
        NSError *err = nil;
        if (![fm removeItemAtPath:targetPath error:&err]) {
            NSLog(@"deployInterpreter: failed to remove existing %@: %@", targetPath, err);
            return NO;
        }
    }

    NSString *realPath = interpreterPath;
    @try {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/bin/readlink"];
        [task setArguments:@[@"-f", interpreterPath]];
        NSPipe *pipe = [NSPipe pipe];
        [task setStandardOutput:pipe];
        [task launch];
        [task waitUntilExit];
        if ([task terminationStatus] == 0) {
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([result length] > 0) {
                realPath = result;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"Warning: could not resolve symlink for %@: %@", interpreterPath, e);
    }

    NSError *err = nil;
    NSString *targetDir = [targetPath stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:targetDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&err]) {
        NSLog(@"deployInterpreter: failed to create directory %@: %@", targetDir, err);
        return NO;
    }

    if (![fm copyItemAtPath:realPath toPath:targetPath error:&err]) {
        NSLog(@"deployInterpreter: failed to copy %@ to %@: %@", realPath, targetPath, err);
        return NO;
    }

    @try {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/bin/chmod"];
        [task setArguments:@[@"0755", targetPath]];
        [task launch];
        [task waitUntilExit];
        if ([task terminationStatus] != 0) {
            NSLog(@"deployInterpreter: chmod failed for %@", targetPath);
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"deployInterpreter: chmod exception: %@", exception);
        return NO;
    }

    return YES;
}

- (BOOL)patchInterpreter:(NSString *)deployedPath
{
    NSError *err = nil;
    NSData *fileData = [NSData dataWithContentsOfFile:deployedPath options:0 error:&err];
    if (!fileData) {
        NSLog(@"patchInterpreter: failed to read %@: %@", deployedPath, err);
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
                                                  length:tbl[i].len
                                            freeWhenDone:NO];
        NSData *replaceData = [NSData dataWithBytesNoCopy:(void *)tbl[i].replace
                                                   length:tbl[i].len
                                             freeWhenDone:NO];
        NSRange searchRange = NSMakeRange(0, [data length]);
        while (searchRange.location < [data length]) {
            NSRange found = [data rangeOfData:searchData
                                      options:0
                                        range:searchRange];
            if (found.location == NSNotFound) break;
            [data replaceBytesInRange:found
                           withBytes:[replaceData bytes]
                              length:[replaceData length]];
            searchRange.location = found.location + [replaceData length];
            searchRange.length = [data length] - searchRange.location;
        }
    }

    if (![data writeToFile:deployedPath options:NSDataWritingAtomic error:&err]) {
        NSLog(@"patchInterpreter: failed to write %@: %@", deployedPath, err);
        return NO;
    }

    return YES;
}

@end
