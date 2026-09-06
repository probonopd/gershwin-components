/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProfileParser.h"

#include <lcms2.h>

@implementation ProfileParser

- (NSDictionary *)parseProfileAtPath:(NSString *)path
{
    if (!path || ![path length]) return nil;

    const char *cpath = [path UTF8String];
    cmsHPROFILE hProfile = cmsOpenProfileFromFile(cpath, "r");
    if (!hProfile) return nil;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    char buf[256];

    if (cmsGetProfileInfoASCII(hProfile, cmsInfoDescription, "en", "US", buf, sizeof(buf)) > 0) {
        [info setObject:[NSString stringWithUTF8String:buf] forKey:@"description"];
    }

    if (cmsGetProfileInfoASCII(hProfile, cmsInfoCopyright, "en", "US", buf, sizeof(buf)) > 0) {
        [info setObject:[NSString stringWithUTF8String:buf] forKey:@"copyright"];
    }

    if (cmsGetProfileInfoASCII(hProfile, cmsInfoManufacturer, "en", "US", buf, sizeof(buf)) > 0) {
        [info setObject:[NSString stringWithUTF8String:buf] forKey:@"manufacturer"];
    }

    if (cmsGetProfileInfoASCII(hProfile, cmsInfoModel, "en", "US", buf, sizeof(buf)) > 0) {
        [info setObject:[NSString stringWithUTF8String:buf] forKey:@"model"];
    }

    int deviceClass = cmsGetDeviceClass(hProfile);
    NSString *classStr = nil;
    switch (deviceClass) {
        case cmsSigDisplayClass:      classStr = @"Display"; break;
        case cmsSigInputClass:        classStr = @"Input"; break;
        case cmsSigOutputClass:       classStr = @"Output"; break;
        case cmsSigLinkClass:         classStr = @"DeviceLink"; break;
        case cmsSigAbstractClass:     classStr = @"Abstract"; break;
        case cmsSigColorSpaceClass:   classStr = @"ColorSpace"; break;
        case cmsSigNamedColorClass:   classStr = @"NamedColor"; break;
        default:                      classStr = @"Unknown"; break;
    }
    [info setObject:classStr forKey:@"deviceClass"];

    BOOL hasVCGT = cmsIsTag(hProfile, cmsSigVcgtTag);
    [info setObject:[NSNumber numberWithBool:hasVCGT] forKey:@"hasVCGT"];

    cmsCloseProfile(hProfile);

    return info;
}

@end
