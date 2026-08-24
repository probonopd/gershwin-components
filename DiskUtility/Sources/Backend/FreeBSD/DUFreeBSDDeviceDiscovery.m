/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__FreeBSD__)

#import "DUFreeBSDDeviceDiscovery.h"

#import <sys/statvfs.h>

#import "DUErrors.h"
#import "DUFreeBSDGEOMAdapter.h"
#import "DUOpticalMedia.h"
#import "DUParsing.h"
#import "DUPartition.h"
#import "DUPartitionTableParser.h"
#import "DUProcessRunner.h"
#import "DUStorageCapabilities.h"
#import "DUStorageDevice.h"
#import "DUStorageVolume.h"

#pragma mark - Tool cache

@implementation DUFreeBSDToolCache

+ (NSString *)pathForTool:(NSString *)toolName
{
    static NSMutableDictionary<NSString *, NSString *> *cache;
    static NSLock *cacheLock;
    @synchronized (self) {
        if (cache == nil) {
            cache = [NSMutableDictionary dictionary];
            cacheLock = [NSLock new];
        }
    }
    [cacheLock lock];
    NSString *cached = cache[toolName];
    [cacheLock unlock];
    if (cached != nil) {
        return cached.length > 0 ? cached : nil;
    }

    // Empty string marks a negative lookup so absent tools do not trigger
    // a filesystem walk on every capability check.
    NSString *resolved = [DUProcessRunner executablePathForName:toolName];
    [cacheLock lock];
    cache[toolName] = resolved ?: @"";
    [cacheLock unlock];
    return resolved;
}

+ (BOOL)haveTool:(NSString *)toolName
{
    return [self pathForTool:toolName] != nil;
}

+ (BOOL)haveAnyTool:(NSArray<NSString *> *)toolNames
{
    for (NSString *toolName in toolNames) {
        if ([self pathForTool:toolName] != nil) {
            return YES;
        }
    }
    return NO;
}

@end

#pragma mark - Discovery

// "ada0s1" extends "ada0" with s+digits; "ada0p2" and "ada0s1a" do not.
// Only slice-shaped children carry another partition table worth querying
// with `geom part list`, so this bounds the descent to BSD-label nesting.
static BOOL IsSliceShapedChildName(NSString *childName, NSString *parentName)
{
    if (childName.length <= parentName.length ||
        ![childName hasPrefix:parentName]) {
        return NO;
    }
    NSString *suffix = [childName substringFromIndex:parentName.length];
    if ([suffix characterAtIndex:0] != 's' || suffix.length < 2) {
        return NO;
    }
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSUInteger i = 1; i < suffix.length; i++) {
        if (![digits characterIsMember:[suffix characterAtIndex:i]]) {
            return NO;
        }
    }
    return YES;
}

@interface DUFreeBSDDeviceDiscovery ()
// One mount(8) snapshot per discovery run; every tree builder reads it.
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *mountTable;
@end

@implementation DUFreeBSDDeviceDiscovery

- (NSArray<DUStorageObject *> *)discoverObjects:(NSError **)error
{
    NSError *geomError = nil;
    NSArray<NSDictionary<NSString *, id> *> *diskProviders =
        [DUFreeBSDGEOMAdapter listClass:@"disk" name:nil error:&geomError];
    if (diskProviders == nil) {
        // nil means geom itself is unusable; an empty array would mean the
        // machine honestly has no disks, which is not an error.
        if (error != NULL) {
            *error = geomError ?: DUErrorMake(
                DUErrorDiscoveryFailed,
                NSLocalizedString(@"geom could not be run.", nil));
        }
        return nil;
    }

    self.mountTable = [DUFreeBSDGEOMAdapter currentMountTable];

    NSMutableArray<DUStorageObject *> *roots = [NSMutableArray array];
    for (NSDictionary *provider in diskProviders) {
        NSString *name = [DUParsing trimmedString:provider[@"name"]];
        if (name.length == 0) {
            continue;
        }
        // Optical drives also appear in the disk class; they are built from
        // the dedicated cd pass below so media state stays consistent.
        if ([name hasPrefix:@"cd"]) {
            continue;
        }
        /* eMMC boot windows (mmcsd0boot0/boot1) are raw 4 MiB slots for
         * bootloaders - never sensible targets for GUI operations, and
         * listing them invited imaging the wrong "disk". */
        if ([name hasSuffix:@"boot0"] || [name hasSuffix:@"boot1"]) {
            continue;
        }
        DUStorageDevice *device = [self diskFromProvider:provider name:name];
        if (device == nil) {
            continue;
        }
        [self attachPartitionsToDisk:device];
        [roots addObject:device];
    }
    [self attachOpticalDrivesToRoots:roots];
    [self applyDerivedCapabilitiesToRoots:roots];
    return roots;
}

#pragma mark - Disk roots

- (DUStorageDevice *)diskFromProvider:(NSDictionary *)provider
                                 name:(NSString *)name
{
    unsigned long long capacity =
        [DUFreeBSDGEOMAdapter bytesFromGeomSizeToken:
                                  [DUParsing trimmedString:provider[@"mediasize"]]];
    // Zero-size providers are empty card readers or placeholder nodes;
    // showing them invites operations that cannot succeed.
    if (capacity == 0) {
        return nil;
    }
    NSString *descr = [DUParsing trimmedString:provider[@"descr"]];

    DUStorageDevice *device = [[DUStorageDevice alloc]
        initWithIdentifier:[@"freebsd-disk-" stringByAppendingString:name]];
    device.displayName =
        [NSString stringWithFormat:@"%@ (%@)",
             descr.length > 0 ? descr
                              : NSLocalizedString(@"Storage Device", nil),
             [DUParsing humanReadableSizeFromBytes:capacity]];
    device.devicePath = [@"/dev/" stringByAppendingString:name];
    device.backendPath = device.devicePath;
    device.capacityBytes = capacity;
    device.optical = NO;
    device.mediaPresent = NO;

    if ([name hasPrefix:@"da"]) {
        // da covers USB and real SCSI disks; without CAM inquiry data the
        // removable guess stays conservative but the bus naming is honest.
        device.connectionType = @"USB";
        device.removable = YES;
        device.ejectable = NO;
        device.connectionIsInternal = NO;
    } else if ([name hasPrefix:@"ada"]) {
        device.connectionType = @"SATA";
        device.connectionIsInternal = YES;
    } else if ([name hasPrefix:@"nvme"] || [name hasPrefix:@"nvd"]) {
        device.connectionType = @"NVMe";
        device.connectionIsInternal = YES;
    } else if ([name hasPrefix:@"mmcsd"]) {
        device.connectionType = @"SD";
        device.removable = YES;
        device.connectionIsInternal = NO;
    } else {
        device.connectionIsInternal = YES;
    }
    device.readOnly = NO;
    device.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    return device;
}

#pragma mark - Partitions

- (void)attachPartitionsToDisk:(DUStorageDevice *)device
{
    NSString *diskName = device.devicePath.lastPathComponent;
    if (diskName.length == 0) {
        return;
    }
    NSArray<NSDictionary<NSString *, id> *> *providers =
        [DUFreeBSDGEOMAdapter listClass:@"part" name:diskName error:NULL];
    if (providers.count == 0) {
        // Blank or unlabeled disk; the scheme stays unknown rather than
        // being invented.
        return;
    }

    // The scheme lives on the enclosing Geom header and is inherited into
    // every provider dictionary by the parser.
    for (NSDictionary *provider in providers) {
        NSString *rawScheme =
            [DUParsing trimmedString:provider[@"scheme"]];
        if (rawScheme.length > 0) {
            device.partitionScheme =
                [DUPartitionTableParser normalizeSchemeToken:rawScheme];
            break;
        }
    }

    [self attachProviders:providers toParent:device parentName:diskName];
}

// Attaches one level of partition children, then descends into MBR slices
// ("ada0s1") so BSD-label partitions ("ada0s1a") surface instead of hiding
// behind an opaque freebsd slice. The slice-shape test keeps GPT children
// leaf-shaped, so no extra geom runs are made on GPT disks.
- (void)attachProviders:(NSArray<NSDictionary<NSString *, id> *> *)providers
               toParent:(DUStorageObject *)parent
             parentName:(NSString *)parentName
{
    for (NSDictionary *provider in providers) {
        NSString *partName = [DUParsing trimmedString:provider[@"name"]];
        if (partName.length == 0 ||
            [partName isEqualToString:parentName] ||
            ![partName hasPrefix:parentName]) {
            continue;
        }
        DUPartition *partition = [self attachPartitionWithInfo:provider
                                                          name:partName
                                                      toParent:parent];
        if (partition == nil ||
            !IsSliceShapedChildName(partName, parentName)) {
            continue;
        }
        // A slice without a label exits nonzero with an empty table; the
        // adapter answers nil and this loop simply runs zero times.
        NSArray<NSDictionary<NSString *, id> *> *nested =
            [DUFreeBSDGEOMAdapter listClass:@"part" name:partName error:NULL];
        [self attachProviders:nested toParent:partition parentName:partName];
    }
}

// Builds one partition node plus its volume child. Returns the partition so
// the caller can decide whether its subtree hosts another partition table.
- (DUPartition *)attachPartitionWithInfo:(NSDictionary *)info
                                    name:(NSString *)partName
                                toParent:(DUStorageObject *)parent
{
    BOOL readOnly = NO;
    if ([parent isKindOfClass:[DUStorageDevice class]]) {
        readOnly = ((DUStorageDevice *)parent).readOnly;
    } else if ([parent isKindOfClass:[DUPartition class]]) {
        readOnly = ((DUPartition *)parent).readOnly;
    }

    unsigned long long sizeBytes =
        [DUFreeBSDGEOMAdapter bytesFromGeomSizeToken:
                                  [DUParsing trimmedString:info[@"len"]]];
    if (sizeBytes == 0) {
        sizeBytes = [DUFreeBSDGEOMAdapter bytesFromGeomSizeToken:
                                            [DUParsing trimmedString:info[@"mediasize"]]];
    }
    unsigned long long offsetBytes =
        [DUFreeBSDGEOMAdapter bytesFromGeomSizeToken:
                                  [DUParsing trimmedString:info[@"offset"]]];

    DUPartition *partition = [[DUPartition alloc]
        initWithIdentifier:[@"freebsd-part-" stringByAppendingString:partName]];
    partition.backendPath = [@"/dev/" stringByAppendingString:partName];
    partition.partitionType = [DUParsing trimmedString:info[@"type"]];
    partition.filesystemType =
        [DUFreeBSDGEOMAdapter filesystemTokenForPartitionType:
                                  partition.partitionType];
    partition.offsetBytes = offsetBytes;
    partition.sizeBytes = sizeBytes;
    partition.index = (NSInteger)[DUParsing
        unsignedLongLongFromString:[DUParsing trimmedString:info[@"index"]]];
    partition.name = [DUParsing trimmedString:info[@"label"]];
    partition.bootable =
        [DUParsing boolFromToken:[DUParsing trimmedString:info[@"active"]]];
    partition.readOnly = readOnly;

    /* Labelled partitions show their label; unlabelled ones fall back to
     * the provider node (mmcsd0p2), which is unique and matches what the
     * user sees in gpart/lsblk-style listings. */
    NSString *label = partition.name.length > 0
        ? partition.name : partName;
    partition.displayName =
        [NSString stringWithFormat:@"%@ (%@)",
             label,
             [DUParsing humanReadableSizeFromBytes:sizeBytes]];

    // Swap has no user-visible filesystem; everything else mountable gets
    // a volume child carrying the live mount state.
    NSString *fstype = partition.filesystemType;
    if (fstype.length > 0 && ![fstype isEqualToString:@"swap"]) {
        DUStorageVolume *volume = [[DUStorageVolume alloc]
            initWithIdentifier:[@"freebsd-vol-" stringByAppendingString:partName]];
        volume.filesystemType = fstype;
        volume.capacityBytes = sizeBytes;
        volume.readOnly = readOnly;

        NSString *node = [@"/dev/" stringByAppendingString:partName];
        // Operations on a selected volume resolve its device node from
        // here; without it mount/verify would reject the volume despite
        // the capability flags advertising them.
        volume.backendPath = node;
        NSDictionary *mountEntry = self.mountTable[node];
        NSString *mountPoint =
            [DUParsing trimmedString:mountEntry[@"mountPoint"]];
        if (mountPoint.length > 0) {
            struct statvfs stats;
            if (statvfs(mountPoint.fileSystemRepresentation, &stats) == 0) {
                volume.mounted = YES;
                volume.mountPoint = mountPoint;
                volume.capacityBytes =
                    (unsigned long long)stats.f_blocks
                    * (unsigned long long)stats.f_frsize;
                volume.availableBytes =
                    (unsigned long long)stats.f_bavail
                    * (unsigned long long)stats.f_frsize;
                volume.usedBytes =
                    volume.capacityBytes - volume.availableBytes;
            }
        }

        NSString *display = label.length > 0 ? label :
            [DUPartitionTableParser filesystemDisplayName:fstype];
        volume.displayName =
            [NSString stringWithFormat:@"%@ (%@)",
                 display,
                 [DUParsing humanReadableSizeFromBytes:volume.capacityBytes]];
        volume.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
        volume.capabilities.canVerify = [self canCheckFilesystem:fstype];
        volume.capabilities.canRepair = volume.capabilities.canVerify;
        volume.capabilities.canMount =
            !volume.mounted && [DUFreeBSDToolCache haveTool:@"mount"];
        volume.capabilities.canUnmount =
            volume.mounted && [DUFreeBSDToolCache haveTool:@"umount"];
        volume.capabilities.canErase = [self canFormatFilesystem:fstype];
        // Image creation ends in a mandatory SHA-256 comparison of source
        // and written bytes; without a hasher that ending is guaranteed,
        // so the flag stays off instead of promising a doomed copy.
        volume.capabilities.canCreateImage =
            [DUFreeBSDToolCache haveTool:@"dd"] &&
            [DUFreeBSDToolCache haveAnyTool:@[ @"sha256", @"sha256sum" ]];

        partition.volume = volume;
        [partition addChild:volume];
    }

    [parent addChild:partition];
    return partition;
}

#pragma mark - Optical drives

- (void)attachOpticalDrivesToRoots:(NSMutableArray<DUStorageObject *> *)roots
{
    NSArray<NSDictionary<NSString *, id> *> *providers =
        [DUFreeBSDGEOMAdapter listClass:@"cd" name:nil error:NULL];
    if (providers.count > 0) {
        for (NSDictionary *provider in providers) {
            DUStorageDevice *drive =
                [self opticalDriveFromProvider:provider];
            if (drive != nil) {
                [roots addObject:drive];
            }
        }
        return;
    }

    // Without the cd class (very old geom or restricted jail) fall back to
    // the conventional first drive node so the device still shows up.
    // Media state stays unknown instead of being guessed.
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/dev/cd0"]) {
        DUStorageDevice *drive = [[DUStorageDevice alloc]
            initWithIdentifier:@"freebsd-optical-cd0"];
        drive.displayName = NSLocalizedString(@"Optical Drive", nil);
        drive.devicePath = @"/dev/cd0";
        drive.backendPath = drive.devicePath;
        drive.optical = YES;
        drive.mediaPresent = NO;
        drive.readOnly = YES;
        drive.removable = YES;
        drive.ejectable = YES;
        drive.connectionIsInternal = NO;
        drive.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
        drive.capabilities.canEject = [self canEject];
        [roots addObject:drive];
    }
}

- (DUStorageDevice *)opticalDriveFromProvider:(NSDictionary *)provider
{
    NSString *name = [DUParsing trimmedString:provider[@"name"]];
    if (name.length == 0) {
        return nil;
    }
    unsigned long long capacity =
        [DUFreeBSDGEOMAdapter bytesFromGeomSizeToken:
                                  [DUParsing trimmedString:provider[@"mediasize"]]];
    NSString *descr = [DUParsing trimmedString:provider[@"descr"]];

    DUStorageDevice *drive = [[DUStorageDevice alloc]
        initWithIdentifier:[@"freebsd-optical-" stringByAppendingString:name]];
    drive.displayName =
        [NSString stringWithFormat:@"%@",
             descr.length > 0 ? descr
                              : NSLocalizedString(@"Optical Drive", nil)];
    drive.devicePath = [@"/dev/" stringByAppendingString:name];
    drive.backendPath = drive.devicePath;
    drive.capacityBytes = capacity;
    drive.optical = YES;
    drive.mediaPresent = capacity > 0;
    drive.readOnly = YES;
    drive.removable = YES;
    drive.ejectable = YES;
    drive.connectionIsInternal = NO;

    if (drive.mediaPresent) {
        [self attachMediaToDrive:drive name:name capacity:capacity];
    }
    drive.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    drive.capabilities.canEject = [self canEject];
    return drive;
}

- (void)attachMediaToDrive:(DUStorageDevice *)drive
                      name:(NSString *)name
                  capacity:(unsigned long long)capacity
{
    DUOpticalMedia *media = [[DUOpticalMedia alloc]
        initWithIdentifier:[@"freebsd-media-" stringByAppendingString:name]];
    media.displayName = NSLocalizedString(@"Optical Disc", nil);
    media.mediaType = NSLocalizedString(@"Optical Disc", nil);
    media.capacityBytes = capacity;
    // Read-only media is full by definition; rewritable blanks are rare and
    // cannot be detected without burn tooling, so stay conservative.
    media.usedBytes = capacity;
    media.freeBytes = 0;
    media.writable = NO;
    media.ejectable = YES;
    media.backendPath = drive.devicePath;

    // The optical media model carries no mount fields of its own, so live
    // state is expressed through the capability flags only.
    NSDictionary *mountEntry = self.mountTable[drive.devicePath];
    NSString *fstype = [DUParsing trimmedString:mountEntry[@"fstype"]];
    if (fstype.length > 0) {
        media.filesystemType = fstype;
    }
    BOOL mounted = mountEntry != nil;

    media.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    media.capabilities.canMount =
        !mounted && [DUFreeBSDToolCache haveTool:@"mount"];
    media.capabilities.canUnmount =
        mounted && [DUFreeBSDToolCache haveTool:@"umount"];
    media.capabilities.canEject = [self canEject];
    [drive addChild:media];
}

#pragma mark - Derived state

- (BOOL)canEject
{
    return [DUFreeBSDToolCache haveTool:@"cdcontrol"] ||
        [DUFreeBSDToolCache haveTool:@"camcontrol"];
}

// Whether any installed checker understands this filesystem identifier.
- (BOOL)canCheckFilesystem:(NSString *)fstype
{
    if ([fstype isEqualToString:@"ufs"]) {
        return [DUFreeBSDToolCache haveTool:@"fsck_ffs"];
    }
    if ([fstype isEqualToString:@"msdosfs"]) {
        return [DUFreeBSDToolCache haveTool:@"fsck_msdosfs"];
    }
    return NO;
}

- (BOOL)canFormatFilesystem:(NSString *)fstype
{
    if ([fstype isEqualToString:@"ufs"]) {
        return [DUFreeBSDToolCache haveTool:@"newfs"];
    }
    if ([fstype isEqualToString:@"msdosfs"]) {
        return [DUFreeBSDToolCache haveTool:@"newfs_msdos"];
    }
    return NO;
}

// Device/drive-level capabilities depend on which helper tools are present;
// per-volume flags were filled during tree construction.
- (void)applyDerivedCapabilitiesToRoots:(NSArray<DUStorageObject *> *)roots
{
    BOOL canPartition = [DUFreeBSDToolCache haveTool:@"gpart"];
    BOOL canFormatAny =
        [DUFreeBSDToolCache haveTool:@"newfs"] ||
        [DUFreeBSDToolCache haveTool:@"newfs_msdos"];
    BOOL canRestore = [DUFreeBSDToolCache haveTool:@"dd"];
    /* Whole-disk verify fans out over the disk's partitions, so it is
     * available whenever any filesystem checker is installed. */
    BOOL canVerifyAny =
        [DUFreeBSDToolCache haveAnyTool:@[ @"fsck_ffs", @"fsck_msdosfs" ]];
    /* Whole-disk erase destroys the table with gpart before reformatting,
     * so advertising erase without gpart would only buy a late error. */
    BOOL canEraseWholeDisk = canFormatAny && canPartition;
    /* Imaging a disk is a plain byte-stream copy through dd whose result
     * is then SHA-256-verified; both pieces must be installed. */
    BOOL canCreateImage =
        [DUFreeBSDToolCache haveTool:@"dd"] &&
        [DUFreeBSDToolCache haveAnyTool:@[ @"sha256", @"sha256sum" ]];

    for (DUStorageObject *root in roots) {
        if (![root isKindOfClass:[DUStorageDevice class]]) {
            continue;
        }
        DUStorageDevice *device = (DUStorageDevice *)root;
        if (device.optical) {
            continue;
        }
        device.capabilities.canPartition = canPartition;
        device.capabilities.canErase = canEraseWholeDisk;
        device.capabilities.canRestore = canRestore;
        device.capabilities.canVerify = canVerifyAny;
        device.capabilities.canCreateImage = canCreateImage;
        device.capabilities.canEject = NO;
    }
}

@end

#endif /* defined(__FreeBSD__) */
