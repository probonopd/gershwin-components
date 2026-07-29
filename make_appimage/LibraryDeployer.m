/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "LibraryDeployer.h"
#import "LibraryResolver.h"

static NSArray *libcPrefixes(void)
{
    static NSArray *prefixes = nil;
    if (!prefixes) {
        prefixes = @[
            @"ld-",
            @"libBrokenLocale-",
            @"libSegFault",
            @"libanl-",
            @"libc-",
            @"libc.",
            @"libdl-",
            @"libdl.",
            @"libm-",
            @"libm.",
            @"libmemusage",
            @"libmvec-",
            @"libnsl-",
            @"libnss-",
            @"libnss.",
            @"libpcprofile",
            @"libpthread-",
            @"libpthread.",
            @"libresolv-",
            @"libresolv.",
            @"librt-",
            @"librt.",
            @"libthread_db-",
            @"libutil-",
            @"sotruss-lib"
        ];
    }
    return prefixes;
}

@interface LibraryDeployer ()
{
    NSMutableArray *_deployedLibs;
    BOOL _standalone;
    BOOL _verbose;
}
@end

@implementation LibraryDeployer

- (instancetype)initWithAppDir:(NSString *)appDirPath
{
    self = [super init];
    if (self) {
        _appDirPath = [appDirPath copy];
        _deployedLibs = [[NSMutableArray alloc] init];
        _useLibcSubdirectory = NO;
        _standalone = NO;

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
    }
    return self;
}

- (BOOL)isExcluded:(NSString *)libName
{
    // In standalone mode (-s), deploy ALL libraries — no exclusions.
    if (_standalone) return NO;

    NSString *filename = [libName lastPathComponent];

    for (NSString *excluded in _excludedLibraries) {
        if ([filename isEqualToString:excluded]) {
            return YES;
        }
    }

    for (NSString *prefix in libcPrefixes()) {
        if ([filename hasPrefix:prefix]) {
            return YES;
        }
    }

    return NO;
}

- (void)setStandalone:(BOOL)flag { _standalone = flag; }
- (void)setVerbose:(BOOL)flag { _verbose = flag; }

- (BOOL)deployLibrary:(NSString *)libPath
{
    NSString *basename = [libPath lastPathComponent];

    if ([self isExcluded:basename]) {
        if (_verbose) NSLog(@"LibraryDeployer:   Skipping excluded: %@", basename);
        return YES;
    }

    if ([libPath hasPrefix:_appDirPath]) {
        return YES;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:libPath isDirectory:&isDir]) {
        return NO;
    }
    if (isDir) {
        return NO;
    }

    NSString *targetPath;

    if (_useLibcSubdirectory) {
        BOOL isLibc = NO;
        for (NSString *prefix in libcPrefixes()) {
            if ([basename hasPrefix:prefix]) {
                isLibc = YES;
                break;
            }
        }
        if (isLibc) {
            targetPath = [_appDirPath stringByAppendingPathComponent:
                [@"libc" stringByAppendingPathComponent:basename]];
        } else {
            targetPath = [_appDirPath stringByAppendingPathComponent:
                [@"usr/lib" stringByAppendingPathComponent:basename]];
        }
    } else {
        targetPath = [_appDirPath stringByAppendingPathComponent:
            [@"usr/lib" stringByAppendingPathComponent:basename]];
    }

    NSString *targetDir = [targetPath stringByDeletingLastPathComponent];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:targetDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&err]) {
        NSLog(@"LibraryDeployer:   Failed to create target dir %@: %@", targetDir, err);
        return NO;
    }

    @try {
        if ([fm fileExistsAtPath:targetPath]) {
            return YES;
        }
        if (![fm copyItemAtPath:libPath toPath:targetPath error:&err]) {
            if (_verbose) NSLog(@"LibraryDeployer:   Copy failed for %@: %@", basename, err);
            return NO;
        }
    } @catch (NSException *exception) {
        return NO;
    }

    if (_verbose) NSLog(@"LibraryDeployer:   Deployed: %@", basename);
    [_deployedLibs addObject:targetPath];
    return YES;
}

- (BOOL)deployLibraries:(NSArray *)libPaths
{
    if (_verbose) NSLog(@"LibraryDeployer: Deploying %lu libraries to AppDir", (unsigned long)[libPaths count]);
    NSUInteger deployed = 0;
    for (NSString *libPath in libPaths) {
        if ([self deployLibrary:libPath]) {
            deployed++;
        }
    }
    if (_verbose) NSLog(@"LibraryDeployer: Deployed %lu / %lu libraries", (unsigned long)deployed, (unsigned long)[libPaths count]);
    return YES;
}

- (void)setUseLibcSubdirectory:(BOOL)flag
{
    _useLibcSubdirectory = flag;
}

@end
