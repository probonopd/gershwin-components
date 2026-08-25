/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__NetBSD__)

#import "DUNetBSDDeviceDiscovery.h"

#import <sys/statvfs.h>

#import "DUErrors.h"
#import "DUNetBKSDisklabelParser.h"
#import "DUOpticalMedia.h"
#import "DUParsing.h"
#import "DUPartition.h"
#import "DUPartitionTableParser.h"
#import "DUProcessRunner.h"
#import "DUStorageCapabilities.h"
#import "DUStorageDevice.h"
#import "DUStorageVolume.h"

#pragma mark - Tool cache

@implementation DUNetBSDToolCache

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

#pragma mark - Discovery

// NetBSD labels the physical disk with partition letter d; that pseudo entry
// duplicates the device root and is never shown as a child. Letter c spans
// only the NetBSD slice of an MBR disk and stays visible.
static NSString * const kWholeDiskLetter = @"d";

@interface DUNetBSDDeviceDiscovery ()
// One mount -p snapshot per discovery run; every tree builder reads it.
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *mountTable;
@end

@implementation DUNetBSDDeviceDiscovery

+ (NSDictionary<NSString *, NSDictionary *> *)currentMountTable
{
    NSString *mount = [DUNetBSDToolCache pathForTool:@"mount"];
    if (mount == nil) {
        return @{};
    }
    DUProcessResult *result = [DUProcessRunner runExecutable:mount
                                                   arguments:@[ @"-p" ]
                                                       error:NULL];
    if (result == nil || result.standardOutput.length == 0) {
        return @{};
    }

    // mount -p prints fstab-style columns:
    //   /dev/wd0a / ffs rw 1 1
    // Fields are [device] [mountpoint] [fstype] [options] [dump] [pass].
    NSMutableDictionary<NSString *, NSDictionary *> *table =
        [NSMutableDictionary dictionary];
    for (NSString *rawLine in [result.standardOutput
             componentsSeparatedByCharactersInSet:
                 [NSCharacterSet newlineCharacterSet]]) {
        NSArray<NSString *> *fields =
            [[DUParsing trimmedString:rawLine]
                componentsSeparatedByCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
        if (fields.count < 3) {
            continue;
        }
        NSString *device = fields[0];
        NSString *mountPoint = fields[1];
        NSString *fstype = fields[2];
        if (device.length == 0 || mountPoint.length == 0 ||
            fstype.length == 0) {
            continue;
        }
        NSDictionary *entry =
            @{ @"mountPoint" : mountPoint, @"fstype" : fstype };
        table[device] = entry;
        table[device.lastPathComponent] = entry;
    }
    return table;
}

- (NSArray<DUStorageObject *> *)discoverObjects:(NSError **)error
{
    // Disk names come from two independent sources; both are merged so a
    // machine where one of them is unavailable still enumerates its disks.
    NSMutableDictionary<NSString *, NSString *> *descriptions =
        [self diskDescriptionsFromDmesg];
    for (NSString *name in [self diskNamesFromSysctl]) {
        if (descriptions[name] == nil) {
            descriptions[name] = @"";
        }
    }

    NSMutableArray<NSString *> *diskNames = [NSMutableArray array];
    for (NSString *name in descriptions) {
        // Optical units are enumerated from /dev below so media state stays
        // out of the disk pass.
        if ([name length] > 2 &&
            [name characterAtIndex:0] == 'c' &&
            [name characterAtIndex:1] == 'd') {
            continue;
        }
        [diskNames addObject:name];
    }
    [diskNames sortUsingSelector:@selector(compare:)];

    if (descriptions.count == 0) {
        // Neither sysctl nor dmesg produced anything usable; an empty array
        // would claim the machine honestly has no disks.
        if (error != NULL) {
            *error = DUErrorMake(
                DUErrorDiscoveryFailed,
                NSLocalizedString(@"Neither sysctl nor dmesg could enumerate "
                                  @"disks.",
                                  nil));
        }
        return nil;
    }

    self.mountTable = [[self class] currentMountTable];

    NSMutableArray<DUStorageObject *> *roots = [NSMutableArray array];
    for (NSString *name in diskNames) {
        DUStorageDevice *device = [self diskFromName:name
                                         description:descriptions[name]];
        if (device == nil) {
            continue;
        }
        [roots addObject:device];
    }
    [self attachOpticalDrivesToRoots:roots];
    [self applyDerivedCapabilitiesToRoots:roots];
    return roots;
}

#pragma mark - Name sources

// `sysctl -n hw.disknames` prints the kernel's current disk inventory as
// space-separated names, which is authoritative even for hot-plugged units.
- (NSArray<NSString *> *)diskNamesFromSysctl
{
    NSString *sysctlPath = [DUNetBSDToolCache pathForTool:@"sysctl"];
    if (sysctlPath == nil) {
        return @[];
    }
    DUProcessResult *result = [DUProcessRunner
        runExecutable:sysctlPath
            arguments:@[ @"-n", @"hw.disknames" ]
                error:NULL];
    if (result == nil || !result.exitedNormally ||
        result.terminationStatus != 0 || result.standardOutput.length == 0) {
        return @[];
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *token in [result.standardOutput
             componentsSeparatedByCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        NSString *name = [DUParsing trimmedString:token];
        if (name.length > 0) {
            [names addObject:name];
        }
    }
    return names;
}

// Boot messages look like:
//   sd0 at scsibus0 targ 0 lun 0: <ATA, Samsung SSD 850, ...> ...
//   wd0 at atabus0 drive 0: <WDC WD800JB-00JJC1>
// The "<...>" span becomes the display description.
- (NSMutableDictionary<NSString *, NSString *> *)diskDescriptionsFromDmesg
{
    NSMutableDictionary<NSString *, NSString *> *descriptions =
        [NSMutableDictionary dictionary];
    NSString *dmesg = [DUNetBSDToolCache pathForTool:@"dmesg"];
    if (dmesg == nil) {
        return descriptions;
    }
    DUProcessResult *result =
        [DUProcessRunner runExecutable:dmesg arguments:@[] error:NULL];
    if (result == nil || result.standardOutput.length == 0) {
        return descriptions;
    }
    NSCharacterSet *spaces = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *rawLine in [result.standardOutput
             componentsSeparatedByCharactersInSet:
                 [NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [DUParsing trimmedString:rawLine];
        NSArray<NSString *> *tokens =
            [line componentsSeparatedByCharactersInSet:spaces];
        if (tokens.count < 2) {
            continue;
        }
        NSString *name = tokens[0];
        // Attach lines only: "sd0 at ..." and nothing else. The first boot
        // line wins because later lines repeat on re-plug without new info.
        if (![tokens[1] isEqualToString:@"at"] || name.length < 3) {
            continue;
        }
        NSRange open = [line rangeOfString:@"<"];
        NSRange close = [line rangeOfString:@">"];
        if (open.location == NSNotFound || close.location == NSNotFound ||
            close.location < open.location) {
            if (descriptions[name] == nil) {
                descriptions[name] = @"";
            }
            continue;
        }
        NSString *description = [DUParsing
            trimmedString:[line substringWithRange:
                                    NSMakeRange(open.location + 1,
                                                close.location -
                                                    open.location - 1)]];
        if (descriptions[name] == nil) {
            descriptions[name] = description;
        }
    }
    return descriptions;
}

#pragma mark - Disk roots

- (DUStorageDevice *)diskFromName:(NSString *)name
                      description:(NSString *)description
{
    NSDictionary<NSString *, id> *label = [self disklabelForDisk:name];
    if (label == nil) {
        // No readable label means no trustworthy geometry; showing a root
        // with invented capacity would invite operations that cannot work.
        return nil;
    }
    unsigned long long sectorSize =
        [label[kDisklabelKeySectorSize] unsignedLongLongValue];
    unsigned long long totalSectors =
        [label[kDisklabelKeyTotalSectors] unsignedLongLongValue];
    if (sectorSize == 0 || totalSectors == 0) {
        return nil;
    }
    unsigned long long capacity = totalSectors * sectorSize;

    DUStorageDevice *device = [[DUStorageDevice alloc]
        initWithIdentifier:[@"netbsd-disk-" stringByAppendingString:name]];
    device.displayName =
        [NSString stringWithFormat:@"%@ (%@)",
             description.length > 0 ? description
                                    : NSLocalizedString(@"Storage Device",
                                                        nil),
             [DUParsing humanReadableSizeFromBytes:capacity]];
    device.devicePath = [@"/dev/" stringByAppendingString:name];
    device.backendPath = device.devicePath;
    device.capacityBytes = capacity;
    device.optical = NO;
    device.mediaPresent = NO;
    device.readOnly = NO;

    // wd is the native ATA/IDE driver family; everything else lands on the
    // SCSI family (sd) or pseudo layers whose bus we do not guess.
    if ([name hasPrefix:@"wd"]) {
        device.connectionType = @"ATA";
        device.connectionIsInternal = YES;
    } else if ([name hasPrefix:@"sd"]) {
        device.connectionType = @"SCSI";
        device.connectionIsInternal = YES;
    } else {
        device.connectionIsInternal = YES;
    }
    device.smartStatus =
        [DUStorageDevice querySmartStatusForPath:device.backendPath];
    device.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];

    for (NSDictionary<NSString *, id> *row in
             label[kDisklabelKeyPartitions]) {
        [self attachPartitionWithRow:row toDisk:device capacity:capacity];
    }
    return device;
}

- (NSDictionary<NSString *, id> *)disklabelForDisk:(NSString *)name
{
    NSString *disklabel = [DUNetBSDToolCache pathForTool:@"disklabel"];
    if (disklabel == nil) {
        return nil;
    }
    DUProcessResult *result = [DUProcessRunner
        runExecutable:disklabel arguments:@[ name ] error:NULL];
    if (result == nil || !result.exitedNormally ||
        result.terminationStatus != 0) {
        return nil;
    }
    return [DUNetBKSDisklabelParser parseDisklabelOutput:
                      result.standardOutput];
}

#pragma mark - Partitions

- (void)attachPartitionWithRow:(NSDictionary<NSString *, id> *)row
                         toDisk:(DUStorageDevice *)device
                       capacity:(unsigned long long)capacity
{
    NSString *letter = row[kDisklabelKeyLetter];
    unsigned long long offsetBytes =
        [row[kDisklabelKeyOffsetBytes] unsignedLongLongValue];
    unsigned long long sizeBytes =
        [row[kDisklabelKeySizeBytes] unsignedLongLongValue];
    if (letter.length == 0 || sizeBytes == 0) {
        return;
    }
    // The whole-disk letter spans exactly the reported capacity; it adds no
    // information beyond the device root itself.
    if ([letter isEqualToString:kWholeDiskLetter] && offsetBytes == 0 &&
        sizeBytes >= capacity) {
        return;
    }

    NSString *node =
        [device.devicePath stringByAppendingString:letter];
    DUPartition *partition = [[DUPartition alloc]
        initWithIdentifier:[@"netbsd-part-"
                               stringByAppendingString:
                                   [device.devicePath.lastPathComponent
                                       stringByAppendingString:letter]]];
    partition.backendPath = node;
    partition.offsetBytes = offsetBytes;
    partition.sizeBytes = sizeBytes;
    partition.index = (NSInteger)([letter characterAtIndex:0] - 'a');
    partition.partitionType = row[kDisklabelKeyFstype];
    partition.filesystemType =
        [self filesystemTokenForLabelType:partition.partitionType];
    partition.name = row[kDisklabelKeyMountPoint];
    partition.bootable =
        [letter isEqualToString:@"a"]; // letter a is the NetBSD root slice
    partition.readOnly = device.readOnly;
    partition.displayName =
        [NSString stringWithFormat:@"%@ (%@)",
             NSLocalizedString(@"Partition", nil),
             [DUParsing humanReadableSizeFromBytes:sizeBytes]];

    NSString *fstype = partition.filesystemType;
    if (fstype.length > 0 && ![fstype isEqualToString:@"swap"]) {
        [self attachVolumeToPartition:partition
                                 node:[node lastPathComponent]
                               fstype:fstype];
    }

    [device addChild:partition];
}

- (void)attachVolumeToPartition:(DUPartition *)partition
                           node:(NSString *)nodeName
                         fstype:(NSString *)fstype
{
    DUStorageVolume *volume = [[DUStorageVolume alloc]
        initWithIdentifier:[@"netbsd-vol-" stringByAppendingString:nodeName]];
    volume.filesystemType = fstype;
    // Volumes carry the partition node themselves; verify, mount and
    // unmount all read the device from here.
    volume.backendPath = partition.backendPath;
    volume.capacityBytes = partition.sizeBytes;
    volume.readOnly = partition.readOnly;

    NSDictionary *mountEntry = self.mountTable[partition.backendPath];
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

    volume.displayName =
        [NSString stringWithFormat:@"%@ (%@)",
             [DUPartitionTableParser filesystemDisplayName:fstype],
             [DUParsing humanReadableSizeFromBytes:volume.capacityBytes]];
    volume.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    volume.capabilities.canVerify =
        [self canCheckFilesystem:fstype];
    volume.capabilities.canRepair = volume.capabilities.canVerify;
    volume.capabilities.canMount =
        !volume.mounted &&
        [DUNetBSDToolCache haveTool:@"mount"];
    volume.capabilities.canUnmount =
        volume.mounted &&
        [DUNetBSDToolCache haveTool:@"umount"];
    volume.capabilities.canErase = [self canFormatFilesystem:fstype];

    partition.volume = volume;
    [partition addChild:volume];
}

// Raw disklabel fstype token to canonical filesystem identifier. Anything
// this backend cannot name (RAID, ccd, unused, unknown) maps to nil so the
// partition shows raw type text instead of a guessed filesystem.
- (NSString *)filesystemTokenForLabelType:(NSString *)labelType
{
    NSDictionary<NSString *, NSString *> *table = @{
        @"4.2BSD" : @"ufs",
        @"MSDOS" : @"vfat",
        @"NTFS" : @"ntfs",
        @"ext2fs" : @"ext2",
        @"ISO9660" : @"cd9660",
        @"swap" : @"swap",
    };
    return table[[DUParsing trimmedString:labelType] ?: @""];
}

#pragma mark - Optical drives

- (void)attachOpticalDrivesToRoots:(NSMutableArray<DUStorageObject *> *)roots
{
    // Presence of any cd<N>d block node reports the drive; d is the NetBSD
    // whole-unit letter. Media state is deliberately unknown rather than
    // guessed from node contents.
    NSError *listError = nil;
    NSArray<NSString *> *nodes = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:@"/dev" error:&listError];
    if (nodes == nil) {
        return;
    }
    NSMutableSet<NSString *> *units = [NSMutableSet set];
    for (NSString *node in nodes) {
        if (![node hasPrefix:@"cd"] || node.length < 4 ||
            ![node hasSuffix:@"d"]) {
            continue;
        }
        NSString *digits =
            [node substringWithRange:NSMakeRange(2, node.length - 3)];
        BOOL allDigits = digits.length > 0;
        for (NSUInteger i = 0; i < digits.length && allDigits; i++) {
            unichar c = [digits characterAtIndex:i];
            allDigits = c >= '0' && c <= '9';
        }
        if (allDigits) {
            [units addObject:[node substringToIndex:node.length - 1]];
        }
    }

    NSMutableArray<NSString *> *sortedUnits =
        [NSMutableArray arrayWithArray:[units allObjects]];
    [sortedUnits sortUsingSelector:@selector(compare:)];
    for (NSString *unit in sortedUnits) {
        DUStorageDevice *drive = [[DUStorageDevice alloc]
            initWithIdentifier:[@"netbsd-optical-"
                                   stringByAppendingString:unit]];
        drive.displayName = NSLocalizedString(@"Optical Drive", nil);
        drive.devicePath = [@"/dev/" stringByAppendingPathComponent:unit];
        drive.backendPath = drive.devicePath;
        drive.optical = YES;
        drive.mediaPresent = NO;
        drive.readOnly = YES;
        drive.removable = YES;
        drive.ejectable = YES;
        drive.connectionIsInternal = NO;
        drive.connectionType = @"SCSI";
        drive.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
        drive.capabilities.canEject =
            [DUNetBSDToolCache haveTool:@"eject"];
        // Burning needs a cdrecord-family tool (run out of process per
        // LIBRARIES.md section 26); without one the toolbar Burn stays
        // disabled.
        drive.capabilities.canBurn = NO;
        for (NSString *cand in @[ @"cdrecord", @"wodim", @"xorriso",
                                    @"growisofs" ]) {
            if ([DUNetBSDToolCache haveTool:cand]) {
                drive.capabilities.canBurn = YES;
                break;
            }
        }
        [roots addObject:drive];
    }
}

#pragma mark - Derived state

- (BOOL)canCheckFilesystem:(NSString *)fstype
{
    if ([fstype isEqualToString:@"ufs"]) {
        return [DUNetBSDToolCache haveTool:@"fsck_ffs"];
    }
    if ([fstype isEqualToString:@"vfat"]) {
        return [DUNetBSDToolCache haveTool:@"fsck_msdos"];
    }
    return NO;
}

- (BOOL)canFormatFilesystem:(NSString *)fstype
{
    if ([fstype isEqualToString:@"ufs"]) {
        return [DUNetBSDToolCache haveTool:@"newfs"];
    }
    if ([fstype isEqualToString:@"vfat"]) {
        return [DUNetBSDToolCache haveTool:@"newfs_msdos"];
    }
    return NO;
}

// Device-level capabilities depend on which helper tools are present;
// per-volume flags were filled during tree construction.
- (void)applyDerivedCapabilitiesToRoots:(NSArray<DUStorageObject *> *)roots
{
    BOOL canPartition = [DUNetBSDToolCache haveTool:@"disklabel"];
    BOOL canFormatAny =
        [DUNetBSDToolCache haveTool:@"newfs"] ||
        [DUNetBSDToolCache haveTool:@"newfs_msdos"];
    BOOL canRestore = [DUNetBSDToolCache haveTool:@"dd"];

    for (DUStorageObject *root in roots) {
        if (![root isKindOfClass:[DUStorageDevice class]]) {
            continue;
        }
        DUStorageDevice *device = (DUStorageDevice *)root;
        if (device.optical) {
            continue;
        }
        device.capabilities.canPartition = canPartition;
        device.capabilities.canErase = canFormatAny;
        device.capabilities.canRestore = canRestore;
        device.capabilities.canEject = NO;
    }
}

@end

#endif /* defined(__NetBSD__) */
