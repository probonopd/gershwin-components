/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import "DULinuxDeviceDiscovery.h"

#import <sys/statvfs.h>

#import "DUBlkidParser.h"
#import "DUErrors.h"
#import "DULsblkParser.h"
#import "DUOpticalMedia.h"
#import "DUParsing.h"
#import "DUPartition.h"
#import "DUPartitionTableParser.h"
#import "DUProcessRunner.h"
#import "DUStorageCapabilities.h"
#import "DUStorageDevice.h"
#import "DUStorageVolume.h"

// The parser headers document these result keys but keep the symbols in
// their .m files; restate the extern declarations instead of duplicating
// the literal values here.
extern NSString * const kLsblkKeyName;
extern NSString * const kLsblkKeyParentName;
extern NSString * const kLsblkKeyPath;
extern NSString * const kLsblkKeyType;
extern NSString * const kLsblkKeySizeBytes;
extern NSString * const kLsblkKeyFstype;

@implementation DULinuxToolCache

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

@end

@interface DULinuxDeviceDiscovery ()
// Device name -> lsblk row; filled by whichever source succeeded so the
// tree-building code stays identical for both paths.
@property (nonatomic, strong) NSMutableDictionary<NSString *,
                                                  NSDictionary *> *rowsByName;
@property (nonatomic, strong) NSArray<NSDictionary *> *orderedRows;
// Device path -> blkid dictionary from one global probe.
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *blkidByPath;
@end

@implementation DULinuxDeviceDiscovery

- (NSArray<DUStorageObject *> *)discoverObjects:(NSError **)error
{
    self.rowsByName = [NSMutableDictionary dictionary];
    self.orderedRows = @[];
    self.blkidByPath = @{};

    if (![self loadRowsViaLsblk] && ![self loadRowsViaSysfs]) {
        if (error != NULL) {
            *error = DUErrorMake(DUErrorDiscoveryFailed,
                                 NSLocalizedString(@"No storage information "
                                                    @"source was reachable.",
                                                   nil));
        }
        return nil;
    }

    [self loadBlkidMap];
    return [self buildTree];
}

#pragma mark - Row sources

- (BOOL)loadRowsViaLsblk
{
    NSString *lsblk = [DUProcessRunner executablePathForName:@"lsblk"];
    if (lsblk == nil) {
        return NO;
    }
    NSError *runError = nil;
    DUProcessResult *result = [DUProcessRunner
        runExecutable:lsblk
            arguments:@[ @"-P", @"-b", @"-o",
                         @"NAME,PKNAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINT,LABEL,PARTUUID,UUID,MODEL,RO,RM,HOTPLUG,MAJ:MIN" ]
                 error:&runError];
    if (result == nil || !result.exitedNormally ||
        WEXITSTATUS(result.terminationStatus) > 1) {
        // Exit 2 means "no devices" on some lsblk versions; anything above
        // is a real failure worth reporting through the fallback instead
        // of aborting discovery outright.
    }
    if (result == nil) {
        return NO;
    }

    NSArray<NSDictionary *> *rows =
        [DULsblkParser parsePairsOutput:result.standardOutput];
    if (rows.count == 0 && result.standardOutput.length == 0 &&
        WEXITSTATUS(result.terminationStatus) != 0) {
        return NO;
    }
    for (NSDictionary *row in rows) {
        NSString *name = row[kLsblkKeyName];
        if (name.length == 0) {
            continue;
        }
        self.rowsByName[name] = row;
    }
    self.orderedRows = rows;
    return YES;
}

// Minimal inventory straight from sysfs when lsblk is unavailable. Sizes
// come from the kernel's 512-byte sector counts; filesystem metadata is
// unknown here and left unset rather than guessed.
- (BOOL)loadRowsViaSysfs
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *names =
        [fileManager contentsOfDirectoryAtPath:@"/sys/block" error:NULL];
    if (names.count == 0) {
        return NO;
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSMutableArray<NSString *> *sorted =
        [[names sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    for (NSString *name in sorted) {
        BOOL isOptical = [name hasPrefix:@"sr"];
        // Loop, ram and mapper devices carry no user-relevant storage state
        // at this level; the lsblk path skips their kinds as well.
        if ([name hasPrefix:@"loop"] || [name hasPrefix:@"ram"] ||
            [name hasPrefix:@"zram"] || [name hasPrefix:@"dm-"] ||
            [name hasPrefix:@"md"]) {
            continue;
        }
        unsigned long long sizeBytes =
            [self sysfsSizeForPath:[@"/sys/block/"
                stringByAppendingPathComponent:name]];
        if (sizeBytes == 0 && !isOptical) {
            continue;
        }
        NSMutableDictionary<NSString *, id> *row =
            [NSMutableDictionary dictionaryWithDictionary:@{
                kLsblkKeyName : name,
                kLsblkKeyPath : [@"/dev/" stringByAppendingString:name],
                kLsblkKeyType : isOptical ? @"rom" : @"disk",
                kLsblkKeyReadOnly :
                    @([self sysfsFlagForKey:@"ro" under:name]),
                kLsblkKeyRemovable :
                    @([self sysfsFlagForKey:@"removable" under:name]),
            }];
        if (sizeBytes > 0) {
            row[kLsblkKeySizeBytes] = @(sizeBytes);
        }
        NSString *model = [NSString
            stringWithContentsOfFile:[@"/sys/block/"
                    stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%@/device/model", name]]
                            encoding:NSUTF8StringEncoding
                               error:NULL];
        if ([DUParsing trimmedString:model].length > 0) {
            row[kLsblkKeyModel] = [DUParsing trimmedString:model];
        }
        [rows addObject:row];
        self.rowsByName[name] = row;

        if (!isOptical) {
            [self collectSysfsPartitionsOfDisk:name intoRows:rows];
        }
    }
    self.orderedRows = rows;
    return rows.count > 0 || names.count > 0;
}

- (void)collectSysfsPartitionsOfDisk:(NSString *)diskName
                           intoRows:(NSMutableArray<NSDictionary *> *)rows
{
    NSString *directory =
        [@"/sys/block/" stringByAppendingPathComponent:diskName];
    NSArray<NSString *> *entries =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:directory error:NULL];
    for (NSString *entry in entries) {
        if (![entry hasPrefix:diskName] || entry.length <= diskName.length) {
            continue;
        }
        NSString *suffix =
            [entry substringFromIndex:diskName.length];
        NSRange invalid =
            [suffix rangeOfCharacterFromSet:
                        [[NSCharacterSet decimalDigitCharacterSet]
                            invertedSet]];
        if (invalid.location != NSNotFound) {
            continue;
        }
        unsigned long long sizeBytes = [self sysfsSizeForPath:
            [directory stringByAppendingPathComponent:entry]];
        NSMutableDictionary<NSString *, id> *row =
            [NSMutableDictionary dictionaryWithDictionary:@{
                kLsblkKeyName : entry,
                kLsblkKeyParentName : diskName,
                kLsblkKeyPath : [@"/dev/" stringByAppendingString:entry],
                kLsblkKeyType : @"part",
            }];
        if (sizeBytes > 0) {
            row[kLsblkKeySizeBytes] = @(sizeBytes);
        }
        [rows addObject:row];
        self.rowsByName[entry] = row;
    }
}

- (unsigned long long)sysfsSizeForPath:(NSString *)path
{
    NSString *text = [NSString
        stringWithContentsOfFile:[path stringByAppendingPathComponent:@"size"]
                        encoding:NSUTF8StringEncoding
                           error:NULL];
    if (text.length == 0) {
        return 0;
    }
    // Kernel block sizes are always reported in 512-byte sectors.
    return [DUParsing unsignedLongLongFromString:
                       [DUParsing trimmedString:text]] * 512ull;
}

- (BOOL)sysfsFlagForKey:(NSString *)key under:(NSString *)deviceName
{
    NSString *text = [NSString stringWithContentsOfFile:
                               [@"/sys/block/"
                  stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@/%@", deviceName, key]]
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
    return [text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]]
               .length > 0 &&
        [[text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]]
            hasPrefix:@"1"];
}

#pragma mark - blkid enrichment

- (void)loadBlkidMap
{
    NSString *blkid = [DUProcessRunner executablePathForName:@"blkid"];
    if (blkid == nil) {
        return;
    }
    DUProcessResult *result =
        [DUProcessRunner runExecutable:blkid arguments:@[] error:NULL];
    if (result == nil || result.standardOutput.length == 0) {
        return;
    }
    // Enrichment is opportunistic: lsblk already supplied most fields, so a
    // failing or partial blkid never fails discovery itself.
    NSMutableDictionary<NSString *, NSDictionary *> *map =
        [NSMutableDictionary dictionary];
    for (NSDictionary *entry in
             [DUBlkidParser parseFullOutput:result.standardOutput]) {
        NSString *device = entry[kBkidKeyDevice];
        if (device.length > 0) {
            map[device] = entry;
        }
    }
    self.blkidByPath = map;
}

- (NSDictionary *)blkidEntryForPath:(NSString *)path
{
    return path.length > 0 ? self.blkidByPath[path] : nil;
}

#pragma mark - Tree construction

- (NSArray<DUStorageObject *> *)buildTree
{
    NSMutableArray<DUStorageObject *> *roots = [NSMutableArray array];

    for (NSDictionary *row in self.orderedRows) {
        NSString *type = row[kLsblkKeyType];
        NSString *parentName = row[kLsblkKeyParentName];
        if (parentName.length > 0) {
            // Partitions attach to their parent while it is visited.
            continue;
        }
        if ([type isEqualToString:@"disk"]) {
            DUStorageDevice *device = [self deviceFromRow:row];
            [self attachPartitionsToDisk:device];
            [roots addObject:device];
        } else if ([type isEqualToString:@"rom"]) {
            DUStorageDevice *drive = [self opticalDriveFromRow:row];
            [roots addObject:drive];
        }
        // Everything else without a parent (loop devices etc.) is skipped
        // entirely; loop mounts belong to their owning applications.
    }
    [self applyDerivedCapabilitiesToRoots:roots];
    return roots;
}

- (DUStorageDevice *)deviceFromRow:(NSDictionary *)row
{
    NSString *name = row[kLsblkKeyName];
    unsigned long long capacity =
        [row[kLsblkKeySizeBytes] unsignedLongLongValue];
    NSString *model =
        [DUParsing trimmedString:row[kLsblkKeyModel]];

    DUStorageDevice *device =
        [[DUStorageDevice alloc]
            initWithIdentifier:[@"linux-disk-" stringByAppendingString:name]];
    device.displayName =
        [NSString stringWithFormat:@"%@ (%@)",
             model.length > 0 ? model
                              : NSLocalizedString(@"Storage Device", nil),
             [DUParsing humanReadableSizeFromBytes:capacity]];
    device.backendPath = row[kLsblkKeyPath] ?: device.devicePath;
    device.devicePath = row[kLsblkKeyPath];
    device.capacityBytes = capacity;
    device.readOnly = [self boolValue:row[kLsblkKeyReadOnly]];
    device.removable = [self boolValue:row[kLsblkKeyRemovable]];
    // Hotplug/removable media is treated as external; fixed disks count as
    // internal. This mirrors how desktop environments classify drives.
    device.connectionIsInternal =
        !device.removable && ![self boolValue:row[kLsblkKeyHotplug]];
    device.connectionType =
        device.removable ? @"USB" : nil;
    device.optical = NO;
    device.mediaPresent = NO;
    device.partitionScheme = [self partitionSchemeForDeviceRow:row];

    device.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    return device;
}

// Whole-disk probing via blkid reports the table type (PTTYPE); normalize
// it to the application vocabulary. Missing blkid simply leaves the scheme
// unknown instead of inventing one.
- (NSString *)partitionSchemeForDeviceRow:(NSDictionary *)row
{
    NSDictionary *entry = [self blkidEntryForPath:row[kLsblkKeyPath]];
    NSString *ptType = entry[@"pttype"];
    if (ptType.length == 0) {
        return nil;
    }
    return [DUPartitionTableParser normalizeSchemeToken:ptType];
}

- (DUStorageDevice *)opticalDriveFromRow:(NSDictionary *)row
{
    NSString *name = row[kLsblkKeyName];
    unsigned long long capacity =
        [row[kLsblkKeySizeBytes] unsignedLongLongValue];
    NSString *model = [DUParsing trimmedString:row[kLsblkKeyModel]];

    DUStorageDevice *drive = [[DUStorageDevice alloc]
        initWithIdentifier:[@"linux-optical-" stringByAppendingString:name]];
    drive.displayName = [NSString stringWithFormat:@"%@ (%@)",
                             model.length > 0 ? model
                                              : NSLocalizedString(
                                                    @"Optical Drive", nil),
                             [DUParsing humanReadableSizeFromBytes:capacity]];
    drive.backendPath = row[kLsblkKeyPath];
    drive.devicePath = row[kLsblkKeyPath];
    drive.capacityBytes = capacity;
    drive.readOnly = YES;
    drive.removable = YES;
    drive.ejectable = YES;
    drive.connectionIsInternal = NO;
    drive.optical = YES;
    drive.mediaPresent = capacity > 0;

    if (drive.mediaPresent) {
        DUOpticalMedia *media = [[DUOpticalMedia alloc]
            initWithIdentifier:[@"linux-media-" stringByAppendingString:name]];
        NSString *label = [DUParsing trimmedString:row[kLsblkKeyLabel]];
        media.displayName =
            label.length > 0 ? label
                             : NSLocalizedString(@"Optical Disc", nil);
        media.mediaType = NSLocalizedString(@"Optical Disc", nil);
        media.filesystemType =
            [DUParsing trimmedString:row[kLsblkKeyFstype]] ?: @"iso9660";
        media.capacityBytes = capacity;
        media.usedBytes = capacity;
        media.freeBytes = 0;
        media.writable = NO;
        media.ejectable = YES;
        media.backendPath = row[kLsblkKeyPath];

        media.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
        media.capabilities.canMount = YES;
        media.capabilities.canEject =
            [DULinuxToolCache haveTool:@"eject"];
        [drive addChild:media];
    }

    drive.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    drive.capabilities.canEject = [DULinuxToolCache haveTool:@"eject"];
    return drive;
}

- (void)attachPartitionsToDisk:(DUStorageDevice *)device
{
    NSString *diskName = [device.identifier
        stringByReplacingOccurrencesOfString:@"linux-disk-"
                                  withString:@""];

    NSInteger index = 0;
    for (NSDictionary *row in self.orderedRows) {
        if (![row[kLsblkKeyType] isEqualToString:@"part"] ||
            ![row[kLsblkKeyParentName] isEqualToString:diskName]) {
            continue;
        }
        NSString *partName = row[kLsblkKeyName];
        unsigned long long partSize =
            [row[kLsblkKeySizeBytes] unsignedLongLongValue];

        DUPartition *partition =
            [[DUPartition alloc]
                initWithIdentifier:[@"linux-part-" stringByAppendingString:
                                             partName]];
        partition.displayName =
            [NSString stringWithFormat:@"%@ (%@)",
                 [DUParsing trimmedString:row[kLsblkKeyLabel]].length > 0
                     ? [DUParsing trimmedString:row[kLsblkKeyLabel]]
                     : NSLocalizedString(@"Partition", nil),
                 [DUParsing humanReadableSizeFromBytes:partSize]];
        partition.backendPath = row[kLsblkKeyPath] ?: partName;
        partition.index = index++;
        partition.sizeBytes = partSize;
        partition.filesystemType =
            [DUParsing trimmedString:row[kLsblkKeyFstype]];
        partition.partitionType =
            [self blkidEntryForPath:row[kLsblkKeyPath]][@"parttype"];
        partition.readOnly = device.readOnly;

        NSString *fstype = partition.filesystemType;
        if (fstype.length > 0 && ![fstype isEqualToString:@"swap"]) {
            DUStorageVolume *volume =
                [[DUStorageVolume alloc]
                    initWithIdentifier:[@"linux-vol-" stringByAppendingString:
                                                 partName]];
            volume.filesystemType = fstype;
            volume.capacityBytes = partSize;
            NSString *mountPoint =
                [DUParsing trimmedString:row[kLsblkKeyMountPoint]];
            if (mountPoint.length > 0) {
                // statvfs fills the usage fields only while the filesystem
                // is actually mounted; otherwise they stay unknown.
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
                    volume.usedBytes = volume.capacityBytes - volume.availableBytes;
                }
            }
            NSDictionary *entry =
                [self blkidEntryForPath:row[kLsblkKeyPath]];
            NSString *label = [DUParsing trimmedString:entry[@"label"]];
            NSString *uuid = [DUParsing trimmedString:entry[@"uuid"]];
            NSString *display =
                label.length > 0 ? label
                                 : [DUPartitionTableParser
                                       filesystemDisplayName:fstype];
            volume.displayName =
                [NSString stringWithFormat:@"%@ (%@)",
                     display,
                     [DUParsing humanReadableSizeFromBytes:
                                       volume.capacityBytes]];
            volume.readOnly = device.readOnly;
            volume.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
            volume.capabilities.canVerify =
                [DULinuxToolCache haveTool:
                       [@"fsck." stringByAppendingString:fstype]];
            volume.capabilities.canRepair = volume.capabilities.canVerify;
            volume.capabilities.canMount = !volume.mounted;
            volume.capabilities.canUnmount = volume.mounted;
            volume.capabilities.canErase =
                [DULinuxToolCache haveTool:
                       [@"mkfs." stringByAppendingString:fstype]] ||
                [DULinuxToolCache haveTool:@"mkfs.ext4"];
            (void)uuid; // retained for future stable re-identification

            partition.volume = volume;
            [partition addChild:volume];
        }

        // A partition acts on the filesystem it carries; without this the
        // UI would treat every partition row as fully incapable whenever
        // no volume was carved out yet.
        DUStorageCapabilities *partitionCaps =
            [DUStorageCapabilities capabilitiesWithAll:NO];
        if (partition.volume != nil) {
            DUStorageCapabilities *volumeCaps = partition.volume.capabilities;
            partitionCaps.canVerify = volumeCaps.canVerify;
            partitionCaps.canRepair = volumeCaps.canRepair;
            partitionCaps.canMount = volumeCaps.canMount;
            partitionCaps.canUnmount = volumeCaps.canUnmount;
            partitionCaps.canErase =
                volumeCaps.canErase ||
                [DULinuxToolCache haveTool:@"mkfs.ext4"];
        } else {
            partitionCaps.canErase =
                [DULinuxToolCache haveTool:@"mkfs.ext4"];
        }
        partitionCaps.canCreateImage = YES;
        partition.capabilities = partitionCaps;

        [device addChild:partition];
    }
}

#pragma mark - Derived state

- (BOOL)boolValue:(NSNumber *)value
{
    return value.boolValue;
}

// Device/drive-level capabilities depend on which helper tools are present;
// per-volume flags were already filled during tree construction.
- (void)applyDerivedCapabilitiesToRoots:(NSArray<DUStorageObject *> *)roots
{
    BOOL canEject = [DULinuxToolCache haveTool:@"eject"];
    BOOL canPartition =
        [DULinuxToolCache haveTool:@"sfdisk"] || [DULinuxToolCache haveTool:@"parted"];
    BOOL canFormatAny =
        [DULinuxToolCache haveTool:@"mkfs.ext4"] || [DULinuxToolCache haveTool:@"mkfs.vfat"];

    for (DUStorageObject *root in roots) {
        if (![root isKindOfClass:[DUStorageDevice class]]) {
            continue;
        }
        DUStorageDevice *device = (DUStorageDevice *)root;
        device.capabilities.canPartition = canPartition && !device.optical;
        device.capabilities.canErase = canFormatAny && !device.optical;
        device.capabilities.canEject = device.ejectable && canEject;
        device.capabilities.canMount = NO;
        device.capabilities.canUnmount = NO;
        device.capabilities.canVerify = YES;
        device.capabilities.canRepair =
            [DULinuxToolCache haveTool:@"fsck.ext4"];
        device.capabilities.canRestore =
            [DULinuxToolCache haveTool:@"dd"];
        // Raw and gzip streaming need no external tool beyond gzip.
        device.capabilities.canCreateImage = YES;
    }
}

@end

#endif /* defined(__linux__) */
