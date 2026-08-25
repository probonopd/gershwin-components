/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import "DULinuxDeviceDiscovery.h"

#import <sys/statvfs.h>

#import "DUBlkidLibrary.h"
#import "DUBlkidParser.h"
#import "DUErrors.h"
#import "DUFdiskLibrary.h"
#import "DULsblkParser.h"
#import "DUExt2Library.h"
#import "DUMountLibrary.h"
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
// Device path -> in-process libblkid superblock probe; entries exist only
// for nodes whose probe recognized a filesystem.
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *probedByPath;
// Mount device -> mount point from the libmount table snapshot.
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *mountPointsByDevice;
// Whole-disk path -> libfdisk table inspection; entries exist only for
// disks whose tables the library recognized.
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *fdiskInspectionByPath;
@end

@implementation DULinuxDeviceDiscovery

- (NSArray<DUStorageObject *> *)discoverObjects:(NSError **)error
{
    self.rowsByName = [NSMutableDictionary dictionary];
    self.orderedRows = @[];
    self.blkidByPath = @{};
    self.probedByPath = @{};
    self.mountPointsByDevice = @{};
    self.fdiskInspectionByPath = @{};

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
    [self loadInProcessProbes];
    [self loadMountTable];
    [self loadFdiskInspections];
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

// Preferred per-node probing through libblkid (LIBRARIES.md section 6.1):
// one in-process probe per leaf device instead of a spawned blkid(8). The
// command snapshot stays loaded as fallback and still supplies the table/
// partition tokens (pttype/parttype) the library interface does not carry.
// Discovery already runs on a background thread; probes stay sequential
// per node exactly like the previous global command pass.
- (void)loadInProcessProbes
{
    if (![DUBlkidLibrary isAvailable]) {
        // Not compiled in: every node answers from the command path below.
        return;
    }
    NSMutableDictionary<NSString *, NSDictionary *> *probes =
        [NSMutableDictionary dictionary];
    for (NSDictionary *row in self.orderedRows) {
        NSString *path = row[kLsblkKeyPath];
        if (path.length == 0 || probes[path] != nil) {
            continue;
        }
        NSDictionary *result = [DUBlkidLibrary probeDevicePath:path];
        // A node without a recognized superblock keeps its command-path
        // entry unchanged instead of being overwritten with nothing.
        if ([DUParsing trimmedString:result[kDUBlkidFstype]].length > 0) {
            probes[path] = result;
        }
    }
    self.probedByPath = probes;
}

// Kernel mount table snapshot via libmount (LIBRARIES.md section 6.3);
// lsblk's MOUNTPOINT column remains the fallback when the library is not
// compiled in or cannot read the table.
- (void)loadMountTable
{
    if (![DUMountLibrary isAvailable]) {
        return;
    }
    NSArray<NSDictionary *> *mounts = [DUMountLibrary listMounts];
    if (mounts == nil) {
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *byDevice =
        [NSMutableDictionary dictionary];
    for (NSDictionary *entry in mounts) {
        NSString *device = [DUParsing trimmedString:entry[kDUMountDevice]];
        NSString *mountPoint = [DUParsing trimmedString:entry[kDUMountPoint]];
        if (device.length > 0 && mountPoint.length > 0 &&
            byDevice[device] == nil) {
            byDevice[device] = mountPoint;
        }
    }
    self.mountPointsByDevice = byDevice;
}

// Whole-disk partition-table inspection via libfdisk (LIBRARIES.md
// section 6.2): the library reads the table directly, ahead of the blkid
// command snapshot's PTTYPE token (library-before-command preference).
// One read-only probe per whole disk; a nil or missing result simply
// leaves the previous sources in charge.
- (void)loadFdiskInspections
{
    if (![DUFdiskLibrary isAvailable]) {
        // Not compiled in: scheme and geometry answer from lsblk/blkid.
        return;
    }
    NSMutableDictionary<NSString *, NSDictionary *> *inspections =
        [NSMutableDictionary dictionary];
    for (NSDictionary *row in self.orderedRows) {
        if (![row[kLsblkKeyType] isEqualToString:@"disk"]) {
            continue;
        }
        NSString *path = row[kLsblkKeyPath];
        if (path.length == 0 || inspections[path] != nil) {
            continue;
        }
        NSDictionary *inspection = [DUFdiskLibrary inspectPath:path];
        if (inspection != nil) {
            inspections[path] = inspection;
        }
    }
    self.fdiskInspectionByPath = inspections;
}

- (NSDictionary *)blkidEntryForPath:(NSString *)path
{
    if (path.length == 0) {
        return nil;
    }
    NSDictionary *probed = self.probedByPath[path];
    if (probed == nil) {
        // Wrapper unavailable or silent for this node: command output only.
        return self.blkidByPath[path];
    }
    // In-process result wins; command-only fields are kept so consumers
    // see one merged dictionary shaped exactly like before.
    NSMutableDictionary *merged = [NSMutableDictionary
        dictionaryWithDictionary:self.blkidByPath[path] ?: @{}];
    merged[kBkidKeyType] = probed[kDUBlkidFstype];
    if (probed[kDUBlkidUuid] != nil) {
        merged[kBkidKeyUuid] = probed[kDUBlkidUuid];
    }
    if (probed[kDUBlkidLabel] != nil) {
        merged[kBkidKeyLabel] = probed[kDUBlkidLabel];
    }
    return merged;
}

#pragma mark - Tree construction

// Mount point of a partition node: libmount's table first (preferred per
// LIBRARIES.md section 6.3), lsblk's MOUNTPOINT column as the fallback
// when the library is absent or lists nothing for this node.
- (NSString *)mountPointForRow:(NSDictionary *)row
{
    NSString *fromTable = self.mountPointsByDevice[row[kLsblkKeyPath]];
    if (fromTable.length > 0) {
        return fromTable;
    }
    return [DUParsing trimmedString:row[kLsblkKeyMountPoint]];
}

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

    // SMART is a whole-disk attribute; query it during discovery so the
    // Info panel can show the drive's self-assessment.
    device.smartStatus =
        [DUStorageDevice querySmartStatusForPath:device.backendPath];

    device.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    return device;
}

// Whole-disk table scheme: libfdisk inspection first (LIBRARIES.md
// preference order - library before command), blkid's PTTYPE snapshot as
// the fallback. Missing sources leave the scheme unknown instead of
// inventing one.
- (NSString *)partitionSchemeForDeviceRow:(NSDictionary *)row
{
    NSDictionary *inspection =
        self.fdiskInspectionByPath[row[kLsblkKeyPath]];
    NSString *scheme =
        [DUParsing trimmedString:inspection[kDUFdiskScheme]];
    if (scheme.length == 0) {
        NSDictionary *entry = [self blkidEntryForPath:row[kLsblkKeyPath]];
        scheme = [DUParsing trimmedString:entry[@"pttype"]];
    }
    if (scheme.length == 0) {
        return nil;
    }
    return [DUPartitionTableParser normalizeSchemeToken:scheme];
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

    // Per-partition geometry from the libfdisk inspection, keyed by
    // partition number; rows without a matching entry keep their
    // lsblk/sysfs values.
    NSDictionary *inspection = self.fdiskInspectionByPath[device.devicePath];
    NSMutableDictionary<NSNumber *, NSDictionary *> *inspectedByNumber =
        [NSMutableDictionary dictionary];
    for (NSDictionary *entry in inspection[kDUFdiskPartitions]) {
        NSNumber *number = entry[kDUFdiskIndex];
        if ([number isKindOfClass:[NSNumber class]]) {
            inspectedByNumber[number] = entry;
        }
    }

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

        // Refine geometry/type/label from the libfdisk table where it saw
        // this partition (library-before-command preference); lsblk does
        // not report offsets at all and its SIZE is kernel-derived.
        NSDictionary *tableEntry =
            inspectedByNumber[[self partitionNumberFromNodeName:partName]];
        if (tableEntry != nil) {
            unsigned long long startBytes =
                [tableEntry[kDUFdiskStartBytes] unsignedLongLongValue];
            unsigned long long entrySizeBytes =
                [tableEntry[kDUFdiskSizeBytes] unsignedLongLongValue];
            if (startBytes > 0) {
                partition.offsetBytes = startBytes;
            }
            if (entrySizeBytes > 0) {
                partition.sizeBytes = entrySizeBytes;
            }
            NSString *type = [DUParsing
                trimmedString:tableEntry[kDUFdiskType]];
            if (type.length > 0) {
                partition.partitionType = type;
            }
            NSString *name = [DUParsing
                trimmedString:tableEntry[kDUFdiskName]];
            if (name.length > 0) {
                partition.name = name;
            }
        }

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
            NSString *mountPoint = [self mountPointForRow:row];
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
            // Unmounted ext volumes have no mount point for statvfs to
            // look at; libext2fs reads their usage straight from the
            // superblock instead (LIBRARIES.md section 7.1). Other
            // unmounted filesystems keep unknown usage rather than a
            // guess from the partition size alone.
            BOOL isExtFilesystemType = [fstype isEqualToString:@"ext2"] ||
                [fstype isEqualToString:@"ext3"] ||
                [fstype isEqualToString:@"ext4"];
            if (!volume.mounted && isExtFilesystemType &&
                [DUExt2Library isAvailable]) {
                NSDictionary *superblockStats =
                    [DUExt2Library statsForPath:volume.backendPath];
                NSNumber *total = superblockStats[kDUExt2TotalBytes];
                NSNumber *free = superblockStats[kDUExt2FreeBytes];
                if ([total isKindOfClass:[NSNumber class]] &&
                    [free isKindOfClass:[NSNumber class]]) {
                    unsigned long long totalBytes = total.unsignedLongLongValue;
                    unsigned long long freeBytes = free.unsignedLongLongValue;
                    volume.capacityBytes = totalBytes;
                    volume.availableBytes = freeBytes;
                    volume.usedBytes =
                        totalBytes > freeBytes ? totalBytes - freeBytes : 0;
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

// Trailing partition number of a kernel node name ("sda1" -> 1,
// "nvme0n1p3" -> 3); nil when the name carries no numeric suffix, which
// would make matching against table entries unreliable.
- (NSNumber *)partitionNumberFromNodeName:(NSString *)nodeName
{
    NSUInteger location = nodeName.length;
    while (location > 0) {
        unichar character = [nodeName characterAtIndex:location - 1];
        if (character < '0' || character > '9') {
            break;
        }
        location--;
    }
    if (location == nodeName.length) {
        return nil;
    }
    return @([nodeName substringFromIndex:location].integerValue);
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
    // Burning runs through whichever cdrecord-family tool is installed
    // (LIBRARIES.md section 1.3: GPL tools, out of process).
    BOOL canBurn =
        [DULinuxToolCache haveTool:@"xorriso"] ||
        [DULinuxToolCache haveTool:@"growisofs"] ||
        [DULinuxToolCache haveTool:@"wodim"] ||
        [DULinuxToolCache haveTool:@"cdrecord"];

    for (DUStorageObject *root in roots) {
        if (![root isKindOfClass:[DUStorageDevice class]]) {
            continue;
        }
        DUStorageDevice *device = (DUStorageDevice *)root;
        device.capabilities.canPartition = canPartition && !device.optical;
        device.capabilities.canErase = canFormatAny && !device.optical;
        device.capabilities.canEject = device.ejectable && canEject;
        device.capabilities.canBurn = canBurn && device.optical;
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
