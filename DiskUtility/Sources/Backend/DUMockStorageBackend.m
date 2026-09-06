/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUMockStorageBackend.h"

#import "DUBackendCapabilities.h"
#import "DUDiskImage.h"
#import "DUErrors.h"
#import "DUOpticalMedia.h"
#import "DUPartition.h"
#import "DUPartitionPlan.h"
#import "DUPartitionTableParser.h"
#import "DUParsing.h"
#import "DURAIDSet.h"
#import "DUStorageCapabilities.h"
#import "DUStorageDevice.h"
#import "DUStorageVolume.h"

// Per-step delay cap keeps contract tests fast even though the overall
// verify arc mimics the ~1.5 s feel of a real fsck run.
static const NSTimeInterval kMockStepDelay = 0.05;
static const unsigned long long kMiB = 1024ull * 1024;
static const unsigned long long kGiB = 1024ull * 1024 * 1024;

@interface DUMockStorageBackend ()
@property (nonatomic, strong) NSMutableArray<DUStorageObject *> *roots;
@property (nonatomic, strong) NSRecursiveLock *lock;
// Identifier -> mount point; the single source of truth for mount state so
// objects without model fields (optical media) stay representable.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *mountPoints;
@property (nonatomic, getter=isDegraded) BOOL degraded;
@end

@implementation DUMockStorageBackend

- (NSArray<NSString *> *)expectedToolNames
{
    return @[];
}

- (instancetype)init
{
    if ((self = [super init]) == nil) {
        return nil;
    }
    _roots = [NSMutableArray array];
    _lock = [NSRecursiveLock new];
    _mountPoints = [NSMutableDictionary dictionary];
    _degraded = NO;
    [self restoreHierarchy];
    return self;
}

+ (instancetype)degradedBackend
{
    DUMockStorageBackend *backend = [[DUMockStorageBackend alloc] init];
    backend.degraded = YES;
    return backend;
}

- (NSArray<DUStorageObject *> *)rootObjects
{
    [self.lock lock];
    NSArray<DUStorageObject *> *snapshot = [self.roots copy];
    [self.lock unlock];
    return snapshot;
}

#pragma mark - Hierarchy construction

- (void)restoreHierarchy
{
    [self.lock lock];
    [self.roots removeAllObjects];
    [self.mountPoints removeAllObjects];

    DUStorageDevice *internal =
        [self deviceWithIdentifier:@"mock-disk-internal"
                              name:@"Internal Disk"
                          capacity:160 * kGiB
                            scheme:@"gpt"
                        connection:@"SATA"
                          internal:YES
                         removable:NO
                         ejectable:NO
                           optical:NO];
    [self attachPartitionWithIdentifier:@"mock-part-system"
                       volumeIdentifier:@"mock-vol-system"
                             volumeName:@"System"
                                 fstype:@"ext4"
                                  bytes:80 * kGiB
                                 offset:kMiB
                                  index:1
                               bootable:YES
                                mounted:@"/"
                                 toDisk:internal];

    [self attachPartitionWithIdentifier:@"mock-part-data"
                       volumeIdentifier:@"mock-vol-data"
                             volumeName:@"Data"
                                 fstype:@"ext4"
                                  bytes:60 * kGiB
                                 offset:81 * kGiB
                                  index:2
                               bootable:NO
                                mounted:nil
                                 toDisk:internal];

    [self attachPartitionWithIdentifier:@"mock-part-recovery"
                       volumeIdentifier:@"mock-vol-recovery"
                             volumeName:@"Recovery"
                                 fstype:@"vfat"
                                  bytes:19 * kGiB
                                 offset:141 * kGiB
                                  index:3
                               bootable:NO
                                mounted:nil
                                 toDisk:internal];

    DUStorageDevice *external =
        [self deviceWithIdentifier:@"mock-disk-external"
                              name:@"External Disk"
                          capacity:500 * kGiB
                            scheme:@"mbr"
                        connection:@"USB"
                          internal:NO
                         removable:YES
                         ejectable:YES
                           optical:NO];
    [self attachPartitionWithIdentifier:@"mock-part-backup"
                       volumeIdentifier:@"mock-vol-backup"
                             volumeName:@"Backup"
                                 fstype:@"ext4"
                                  bytes:500 * kGiB
                                 offset:kMiB
                                  index:1
                               bootable:NO
                                mounted:nil
                                 toDisk:external];

    DUStorageDevice *drive =
        [self deviceWithIdentifier:@"mock-optical-drive"
                              name:@"Optical Drive"
                          capacity:0
                            scheme:nil
                        connection:@"USB"
                          internal:NO
                         removable:YES
                         ejectable:YES
                           optical:YES];

    DUOpticalMedia *media =
        [[DUOpticalMedia alloc] initWithIdentifier:@"mock-media-installation"];
    media.displayName = @"Installation Media";
    media.mediaType = @"DVD-ROM";
    media.filesystemType = @"iso9660";
    media.capacityBytes = 4500 * kMiB;
    media.usedBytes = media.capacityBytes;
    media.freeBytes = 0;
    media.writable = NO;
    media.ejectable = YES;
    media.backendPath = @"/dev/mock/sr0";
    DUStorageCapabilities *mediaCaps =
        [DUStorageCapabilities capabilitiesWithAll:NO];
    mediaCaps.canVerify = YES;
    mediaCaps.canMount = YES;
    mediaCaps.canEject = YES;
    mediaCaps.canBurn = YES;
    media.capabilities = mediaCaps;
    [drive addChild:media];

    DUDiskImage *image = [[DUDiskImage alloc] initWithIdentifier:@"mock-image"];
    image.displayName =
        [NSString stringWithFormat:@"Disk Image (%@)",
             [DUParsing humanReadableSizeFromBytes:8 * kGiB]];
    image.path = @"~/mock-image.raw";
    image.format = @"raw";
    image.sizeBytes = 8 * kGiB;
    image.readOnly = NO;
    image.backendPath = image.path;
    DUStorageCapabilities *imageCaps =
        [DUStorageCapabilities capabilitiesWithAll:NO];
    imageCaps.canVerify = YES;
    imageCaps.canMount = YES;
    imageCaps.canEject = YES;
    imageCaps.canCreateImage = YES;
    imageCaps.canConvertImage = YES;
    imageCaps.canResizeImage = YES;
    imageCaps.canRestore = YES;
    image.capabilities = imageCaps;

    DUStorageVolume *imageVolume =
        [[DUStorageVolume alloc] initWithIdentifier:@"mock-vol-image-volume"];
    imageVolume.displayName = @"Image Volume";
    imageVolume.filesystemType = @"ext4";
    imageVolume.capacityBytes = 8 * kGiB;
    imageVolume.usedBytes = 0;
    imageVolume.availableBytes = 8 * kGiB;
    imageVolume.fileCount = NSNotFound;
    imageVolume.folderCount = NSNotFound;
    imageVolume.backendPath = @"/dev/mock/loop0";
    DUStorageCapabilities *ivCaps =
        [DUStorageCapabilities capabilitiesWithAll:NO];
    ivCaps.canVerify = YES;
    ivCaps.canRepair = YES;
    ivCaps.canErase = YES;
    ivCaps.canMount = YES;
    ivCaps.canResize = YES;
    ivCaps.canRestore = YES;
    imageVolume.capabilities = ivCaps;
    image.backingVolume = imageVolume;
    // The model documents that backingVolume doubles as a child so outline
    // browsers show it as a row.
    [image addChild:imageVolume];

    DURAIDSet *raid = [[DURAIDSet alloc] initWithIdentifier:@"mock-raid-mirror"];
    raid.displayName =
        [NSString stringWithFormat:@"Mirror Set (%@)",
             [DUParsing humanReadableSizeFromBytes:160 * kGiB]];
    raid.raidLevel = @"mirror";
    raid.members = @[ internal, external ];
    raid.capacityBytes = 160 * kGiB;
    raid.status = @"healthy";
    raid.degraded = NO;
    DUStorageCapabilities *raidCaps =
        [DUStorageCapabilities capabilitiesWithAll:NO];
    raidCaps.canVerify = YES;
    raidCaps.canRepair = YES;
    raidCaps.canErase = YES;
    raidCaps.canPartition = YES;
    raidCaps.canRestore = YES;
    raid.capabilities = raidCaps;

    [self.roots addObjectsFromArray:@[ internal, external, drive, image, raid ]];
    [self.lock unlock];
}

- (DUStorageDevice *)deviceWithIdentifier:(NSString *)identifier
                                     name:(NSString *)name
                                 capacity:(unsigned long long)capacity
                                   scheme:(NSString *)scheme
                               connection:(NSString *)connection
                                 internal:(BOOL)internal
                                removable:(BOOL)removable
                                ejectable:(BOOL)ejectable
                                  optical:(BOOL)optical
{
    DUStorageDevice *device =
        [[DUStorageDevice alloc] initWithIdentifier:identifier];
    // Human sizes come from the shared parser so mock and real backends
    // render identically.
    device.displayName =
        [NSString stringWithFormat:@"%@ (%@)", name,
             [DUParsing humanReadableSizeFromBytes:capacity]];
    device.devicePath = [@"/dev/mock/" stringByAppendingString:identifier];
    device.connectionType = connection;
    device.connectionIsInternal = internal;
    device.capacityBytes = capacity;
    device.removable = removable;
    device.ejectable = ejectable;
    device.readOnly = NO;
    device.partitionScheme = scheme;
    device.healthStatus = @"healthy";
    device.smartStatus = DUStorageSmartStatusVerified;
    device.optical = optical;
    device.mediaPresent = optical;

    DUStorageCapabilities *caps = [DUStorageCapabilities capabilitiesWithAll:NO];
    caps.canVerify = YES;
    caps.canPartition = !optical;
    caps.canErase = !optical;
    caps.canEject = ejectable;
    caps.canCreateImage = YES;
    caps.canRestore = YES;
    caps.canBurn = optical;
    device.capabilities = caps;
    return device;
}

- (void)attachPartitionWithIdentifier:(NSString *)identifier
                     volumeIdentifier:(NSString *)volumeIdentifier
                           volumeName:(NSString *)name
                               fstype:(NSString *)fstype
                                bytes:(unsigned long long)bytes
                               offset:(unsigned long long)offset
                                index:(NSInteger)index
                             bootable:(BOOL)bootable
                              mounted:(NSString *)mountPoint
                               toDisk:(DUStorageDevice *)disk
{
    DUStorageVolume *volume =
        [[DUStorageVolume alloc] initWithIdentifier:volumeIdentifier];
    volume.displayName = name;
    volume.filesystemType = fstype;
    volume.capacityBytes = bytes;
    volume.usedBytes = bytes / 3;
    volume.availableBytes = bytes - volume.usedBytes;
    volume.readOnly = NO;
    volume.fileCount = NSNotFound;
    volume.folderCount = NSNotFound;
    DUStorageCapabilities *caps = [DUStorageCapabilities capabilitiesWithAll:NO];
    caps.canVerify = YES;
    caps.canRepair = YES;
    caps.canErase = YES;
    caps.canResize = YES;
    caps.canRestore = YES;
    caps.canToggleJournaling = [fstype isEqualToString:@"ext4"];
    if (mountPoint != nil) {
        self.mountPoints[volumeIdentifier] = mountPoint;
        volume.mounted = YES;
        volume.mountPoint = mountPoint;
        caps.canMount = NO;
        caps.canUnmount = YES;
    } else {
        caps.canMount = YES;
        caps.canUnmount = NO;
    }
    volume.capabilities = caps;

    DUPartition *partition =
        [[DUPartition alloc] initWithIdentifier:identifier];
    partition.displayName =
        [NSString stringWithFormat:@"%@ (%@)", name,
             [DUParsing humanReadableSizeFromBytes:bytes]];
    partition.index = index;
    partition.offsetBytes = offset;
    partition.sizeBytes = bytes;
    partition.name = name;
    partition.partitionType = fstype;
    partition.filesystemType = fstype;
    partition.bootable = bootable;
    partition.volume = volume;
    // The partition row itself carries verify/repair/erase so selecting
    // either row in the browser gates operations identically.
    DUStorageCapabilities *partCaps = [DUStorageCapabilities capabilitiesWithAll:NO];
    partCaps.canVerify = YES;
    partCaps.canRepair = YES;
    partCaps.canErase = YES;
    partCaps.canRestore = YES;
    partition.capabilities = partCaps;

    [disk addChild:partition];
}

#pragma mark - Discovery and capability reporting

- (NSArray *)discoverStorageObjects:(NSError **)error
{
    if (self.isDegraded) {
        if (error != NULL) {
            *error = DUErrorMake(
                DUErrorDiscoveryFailed,
                NSLocalizedString(@"Storage management is not available "
                                   @"on this system. No compatible storage "
                                   @"backend was detected.",
                                   nil));
        }
        return nil;
    }
    return self.rootObjects;
}

- (NSDictionary *)capabilitiesReport
{
    DUBackendReport *report = [[DUBackendReport alloc] init];
    [report setAll:!self.isDegraded];
    return [report reportDictionary];
}

- (NSArray<NSDictionary *> *)supportedFormatsForObject:(DUStorageObject *)object
{
    if (object == nil || object.capabilities.canErase == NO) {
        return @[];
    }

    NSArray<NSString *> *identifiers =
        @[ @"ext4", @"ext3", @"ext2", @"vfat", @"exfat", @"ntfs", @"ufs" ];
    NSMutableArray<NSDictionary *> *formats = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
        [formats addObject:@{
            kDUFormatIdentifierKey : identifier,
            kDUFormatDisplayNameKey :
                [DUPartitionTableParser filesystemDisplayName:identifier],
            kDUFormatCanFormatKey : @YES,
        }];
    }
    return formats;
}

#pragma mark - Operation gating

- (BOOL)supportsOperation:(NSString *)op forObject:(DUStorageObject *)object
{
    if (op == nil || object == nil || object.capabilities == nil) {
        return NO;
    }
    // Degraded mode rejects everything, even if a caller passes an object
    // obtained elsewhere.
    if (self.isDegraded) {
        return NO;
    }
    DUStorageCapabilities *caps = object.capabilities;

    if ([op isEqualToString:kDUOperationVerify]) return caps.canVerify;
    if ([op isEqualToString:kDUOperationRepair]) return caps.canRepair;
    if ([op isEqualToString:kDUOperationErase]) return caps.canErase;
    if ([op isEqualToString:kDUOperationPartition]) return caps.canPartition;
    if ([op isEqualToString:kDUOperationMount]) return caps.canMount;
    if ([op isEqualToString:kDUOperationUnmount]) return caps.canUnmount;
    if ([op isEqualToString:kDUOperationEject]) return caps.canEject;
    if ([op isEqualToString:kDUOperationRestore]) return caps.canRestore;
    if ([op isEqualToString:kDUOperationBurn]) return caps.canBurn;
    if ([op isEqualToString:kDUOperationCreateImage]) return caps.canCreateImage;
    if ([op isEqualToString:kDUOperationConvertImage]) return caps.canConvertImage;
    if ([op isEqualToString:kDUOperationResizeImage]) return caps.canResizeImage;
    if ([op isEqualToString:kDUOperationToggleJournaling]) return caps.canToggleJournaling;
    return NO;
}

- (NSError *)gateForOperation:(NSString *)op onObject:(DUStorageObject *)object
{
    if (object == nil) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No object selected.", nil));
    }
    if (![self supportsOperation:op forObject:object]) {
        return DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"\"%@\" cannot be performed on %@.",
                                   nil),
                 op, object.displayName ?: NSLocalizedString(@"this item", nil)]);
    }
    return nil;
}

#pragma mark - Simulated long-running operations

// Runs work() on a private thread with an autorelease pool. Callbacks are
// delivered on that worker thread; the UI layer marshals to main itself.
- (void)spawnWork:(void (^)(void))work
{
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            work();
        }
    }];
    worker.name = @"DU mock op";
    [worker start];
}

- (void)simulateSteps:(NSUInteger)count
              message:(NSString *)message
             progress:(void (^)(double, NSString *))progress
{
    for (NSUInteger i = 1; i <= count; i++) {
        [NSThread sleepForTimeInterval:kMockStepDelay];
        if (progress != NULL) {
            progress((double)i / (double)count, message);
        }
    }
}

- (void)verifyObject:(DUStorageObject *)object
             progress:(void (^)(double, NSString *))progress
           completion:(void (^)(NSError *))completion
{
    NSError *gate = [self gateForOperation:kDUOperationVerify onObject:object];
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    [self spawnWork:^{
        [self simulateSteps:30
                    message:NSLocalizedString(@"Verifying volume...", nil)
                   progress:progress];
        // The "broken" marker exercises failure paths without real damage.
        NSError *error = nil;
        if ([object.identifier rangeOfString:@"broken"].location != NSNotFound) {
            error = DUErrorMake(DUErrorVerificationFailed,
                                NSLocalizedString(
                                    @"The filesystem was found to be damaged.",
                                    nil));
        }
        if (completion != NULL) {
            completion(error);
        }
    }];
}

- (void)repairObject:(DUStorageObject *)object
             progress:(void (^)(double, NSString *))progress
           completion:(void (^)(NSError *))completion
{
    NSError *gate = [self gateForOperation:kDUOperationRepair onObject:object];
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    [self spawnWork:^{
        [self simulateSteps:24
                    message:NSLocalizedString(@"Repairing filesystem...", nil)
                   progress:progress];
        NSError *error = nil;
        if ([object.identifier rangeOfString:@"broken"].location != NSNotFound) {
            error = DUErrorMake(DUErrorRepairFailed,
                                NSLocalizedString(
                                    @"The filesystem could not be repaired.",
                                    nil));
        }
        if (completion != NULL) {
            completion(error);
        }
    }];
}

- (void)eraseObject:(DUStorageObject *)object
            options:(NSDictionary *)options
           progress:(void (^)(double, NSString *))progress
         completion:(void (^)(NSError *))completion
{
    NSError *gate = [self gateForOperation:kDUOperationErase onObject:object];
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *newFstype = options[kDUFormatIdentifierKey];
    BOOL zeros =
        [options[kDUEraseSecurityMethodKey] isEqualTo:kDUEraseMethodZerosKey];

    [self spawnWork:^{
        NSString *wipeMessage =
            zeros ? NSLocalizedString(@"Writing zeros over the volume...", nil)
                  : NSLocalizedString(@"Erasing volume...", nil);
        [self simulateSteps:zeros ? 20 : 10
                    message:wipeMessage
                   progress:progress];

        [self.lock lock];
        DUStorageVolume *volume = [self volumeForObject:object];
        if (volume != nil) {
            volume.filesystemType = nil;
            volume.displayName = NSLocalizedString(@"Untitled", nil);
            volume.mounted = NO;
            volume.mountPoint = nil;
            DUPartition *host = nil;
            if ([volume.parent isKindOfClass:[DUPartition class]]) {
                host = (DUPartition *)volume.parent;
                host.filesystemType = nil;
                host.partitionType = nil;
            }
            [self forgetMountsUnder:object];
        } else if ([object isKindOfClass:[DUStorageDevice class]]) {
            // Whole-device erase collapses the table into empty space.
            [self removeAllChildrenOf:object];
        }
        [self.lock unlock];

        [self simulateSteps:10
                    message:NSLocalizedString(@"Creating filesystem...", nil)
                   progress:progress];

        NSString *blankFstype = newFstype ?: @"ext4";
        [self.lock lock];
        if (volume != nil) {
            volume.filesystemType = blankFstype;
            volume.usedBytes = 0;
            volume.availableBytes = volume.capacityBytes;
            volume.capabilities.canMount = YES;
            volume.capabilities.canUnmount = NO;
            if ([volume.parent isKindOfClass:[DUPartition class]]) {
                DUPartition *host = (DUPartition *)volume.parent;
                host.filesystemType = blankFstype;
                host.partitionType = blankFstype;
            }
        } else if ([object isKindOfClass:[DUStorageDevice class]]) {
            [self installBlankVolumeWithFstype:blankFstype
                                     onDevice:(DUStorageDevice *)object];
        }
        [self.lock unlock];

        if (completion != NULL) {
            completion(nil);
        }
    }];
}

- (void)partitionDevice:(DUStorageObject *)device
                 withPlan:(DUPartitionPlan *)plan
                progress:(void (^)(double, NSString *))progress
              completion:(void (^)(NSError *))completion
{
    NSError *gate = nil;
    if (device == nil || plan == nil ||
        ![plan.diskIdentifier isEqualToString:device.identifier]) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The partition plan does not "
                                              @"match the selected device.",
                                              nil));
    } else {
        gate = [self gateForOperation:kDUOperationPartition onObject:device];
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSArray<DUPartition *> *entries = plan.entries;
    [self spawnWork:^{
        NSUInteger total = entries.count;
        for (NSUInteger i = 0; i < total; i++) {
            [NSThread sleepForTimeInterval:kMockStepDelay];
            if (progress != NULL) {
                progress((double)(i + 1) / (double)total,
                         [NSString stringWithFormat:
                             NSLocalizedString(@"Creating partition %lu of %lu...",
                                               nil),
                             (unsigned long)(i + 1), (unsigned long)total]);
            }
        }

        [self.lock lock];
        DUStorageDevice *target = (DUStorageDevice *)device;
        [self removeAllChildrenOf:target];
        target.partitionScheme =
            [DUPartitionTableParser normalizeSchemeToken:plan.scheme];
        for (NSUInteger i = 0; i < total; i++) {
            DUPartition *entry = entries[i];
            NSString *identifier = [target.identifier
                stringByAppendingFormat:@"-part%lu", (unsigned long)(i + 1)];
            DUPartition *partition =
                [[DUPartition alloc] initWithIdentifier:identifier];
            partition.index = (NSInteger)(i + 1);
            partition.offsetBytes = entry.offsetBytes;
            partition.sizeBytes = entry.sizeBytes;
            partition.name = entry.name;
            partition.partitionType = entry.partitionType;
            partition.filesystemType = entry.filesystemType;
            partition.bootable = entry.bootable;
            partition.readOnly = entry.readOnly;
            partition.displayName = [NSString stringWithFormat:@"%@ (%@)",
                                        entry.name
                                            ?: NSLocalizedString(@"Untitled",
                                                                 nil),
                                        [DUParsing
                                            humanReadableSizeFromBytes:
                                                entry.sizeBytes]];
            partition.capabilities =
                [DUStorageCapabilities capabilitiesWithAll:NO];
            partition.capabilities.canVerify = YES;
            partition.capabilities.canRepair = YES;
            partition.capabilities.canErase = YES;

            if (entry.filesystemType != nil) {
                DUStorageVolume *volume = [[DUStorageVolume alloc]
                    initWithIdentifier:[identifier
                                           stringByReplacingOccurrencesOfString:
                                               @"-part"
                                                withString:@"-vol"]];
                volume.displayName =
                    entry.name ?: NSLocalizedString(@"Untitled", nil);
                volume.filesystemType = entry.filesystemType;
                volume.capacityBytes = entry.sizeBytes;
                volume.availableBytes = entry.sizeBytes;
                volume.fileCount = NSNotFound;
                volume.folderCount = NSNotFound;
                volume.capabilities =
                    [DUStorageCapabilities capabilitiesWithAll:NO];
                volume.capabilities.canVerify = YES;
                volume.capabilities.canRepair = YES;
                volume.capabilities.canErase = YES;
                volume.capabilities.canMount = YES;
                volume.capabilities.canRestore = YES;
                partition.volume = volume;
            }
            [target addChild:partition];
        }
        [self.lock unlock];

        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Mount management

- (void)mountObject:(DUStorageObject *)object
          completion:(void (^)(NSError *, NSString *))completion
{
    if (object == nil) {
        if (completion != NULL) {
            completion(DUErrorMake(DUErrorInvalidArgument,
                                   NSLocalizedString(@"No object selected.",
                                                     nil)), nil);
        }
        return;
    }

    // Mount state lives on the filesystem, so gate against the resolved
    // volume when the selection was a container row.
    DUStorageVolume *target = [self volumeForObject:object];
    DUStorageObject *gateObject = target ?: object;

    [self.lock lock];
    NSString *existing = [self mountStateForObject:object];
    BOOL allowed = existing != nil || gateObject.capabilities.canMount;
    [self.lock unlock];

    if (!allowed) {
        if (completion != NULL) {
            completion([self gateForOperation:kDUOperationMount
                                     onObject:gateObject], nil);
        }
        return;
    }

    [self spawnWork:^{
        [self.lock lock];
        NSString *mountPoint = [self mountStateForObject:object];
        if (mountPoint == nil) {
            mountPoint =
                [@"/Volumes/" stringByAppendingPathComponent:
                         target.displayName ?: NSLocalizedString(@"Untitled", nil)];
            [self setMountPoint:mountPoint forObjectTree:object];
        }
        [self.lock unlock];
        if (completion != NULL) {
            completion(nil, mountPoint);
        }
    }];
}

- (void)unmountObject:(DUStorageObject *)object
            completion:(void (^)(NSError *))completion
{
    if (object == nil) {
        if (completion != NULL) {
            completion(DUErrorMake(DUErrorInvalidArgument,
                                   NSLocalizedString(@"No object selected.",
                                                     nil)));
        }
        return;
    }

    [self.lock lock];
    BOOL currentlyMounted = [self mountStateForObject:object] != nil;
    DUStorageVolume *target = [self volumeForObject:object];
    DUStorageObject *gateObject = target ?: object;
    BOOL allowed =
        currentlyMounted || gateObject.capabilities.canUnmount;
    [self.lock unlock];

    if (!allowed) {
        if (completion != NULL) {
            completion([self gateForOperation:kDUOperationUnmount
                                     onObject:gateObject]);
        }
        return;
    }

    [self spawnWork:^{
        [self.lock lock];
        [self clearMountStateForObjectTree:object];
        [self.lock unlock];
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

- (void)ejectObject:(DUStorageObject *)object
          completion:(void (^)(NSError *))completion
{
    NSError *gate = [self gateForOperation:kDUOperationEject onObject:object];
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    [self spawnWork:^{
        [NSThread sleepForTimeInterval:kMockStepDelay];
        [self.lock lock];
        DUStorageObject *root = object;
        while (root.parent != nil) {
            root = root.parent;
        }
        if (object.type == DUStorageObjectTypeOpticalMedia &&
            [root isKindOfClass:[DUStorageDevice class]]) {
            // Ejecting a disc empties the drive but keeps it connected;
            // restoreHierarchy puts the medium back on next refresh.
            [self removeAllChildrenOf:root];
            ((DUStorageDevice *)root).mediaPresent = NO;
            [self forgetMountsUnder:object];
        } else {
            [self forgetMountsUnder:root];
            [self.roots removeObjectIdenticalTo:root];
        }
        [self.lock unlock];
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Restore

- (void)restoreFromSource:(DUStorageObject *)source
               destination:(DUStorageObject *)destination
                   options:(NSDictionary *)options
                  progress:(void (^)(double, NSString *))progress
                completion:(void (^)(NSError *))completion
{
    (void)options;
    NSError *gate = nil;
    if (source == nil || destination == nil) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"A source and a destination are "
                                              @"required.",
                                              nil));
    } else if ([source.identifier isEqualToString:destination.identifier]) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The source and destination are "
                                              @"the same.",
                                              nil));
    } else {
        gate = [self gateForOperation:kDUOperationRestore
                             onObject:destination];
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    [self spawnWork:^{
        [self simulateSteps:20
                    message:NSLocalizedString(@"Restoring...", nil)
                   progress:progress];
        // Nothing is copied; the simulation models duration and outcome only.
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Tree and mount-state plumbing

- (void)removeAllChildrenOf:(DUStorageObject *)object
{
    for (DUStorageObject *child in [object.children copy]) {
        [object removeChild:child];
    }
}

// Fresh single-volume table after a whole-device erase.
- (void)installBlankVolumeWithFstype:(NSString *)fstype
                            onDevice:(DUStorageDevice *)device
{
    DUStorageVolume *volume = [[DUStorageVolume alloc]
        initWithIdentifier:[device.identifier stringByAppendingString:@"-vol1"]];
    volume.displayName = NSLocalizedString(@"Untitled", nil);
    volume.filesystemType = fstype;
    volume.capacityBytes = device.capacityBytes;
    volume.availableBytes = device.capacityBytes;
    volume.fileCount = NSNotFound;
    volume.folderCount = NSNotFound;
    volume.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    volume.capabilities.canVerify = YES;
    volume.capabilities.canRepair = YES;
    volume.capabilities.canErase = YES;
    volume.capabilities.canMount = YES;
    volume.capabilities.canRestore = YES;

    DUPartition *partition = [[DUPartition alloc]
        initWithIdentifier:[device.identifier stringByAppendingString:@"-part1"]];
    partition.index = 1;
    partition.sizeBytes = device.capacityBytes;
    partition.name = volume.displayName;
    partition.partitionType = fstype;
    partition.filesystemType = fstype;
    partition.displayName =
        [NSString stringWithFormat:@"%@ (%@)", volume.displayName,
             [DUParsing humanReadableSizeFromBytes:device.capacityBytes]];
    partition.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    partition.capabilities.canVerify = YES;
    partition.capabilities.canRepair = YES;
    partition.capabilities.canErase = YES;
    partition.volume = volume;
    [device addChild:partition];
}

- (DUStorageVolume *)volumeForObject:(DUStorageObject *)object
{
    if (object == nil) {
        return nil;
    }
    if ([object isKindOfClass:[DUStorageVolume class]]) {
        return (DUStorageVolume *)object;
    }
    if ([object isKindOfClass:[DUPartition class]] &&
        ((DUPartition *)object).volume != nil) {
        return ((DUPartition *)object).volume;
    }
    if ([object isKindOfClass:[DUDiskImage class]] &&
        ((DUDiskImage *)object).backingVolume != nil) {
        return ((DUDiskImage *)object).backingVolume;
    }
    return nil;
}

// Mount point for either a bare volume or any container owning one; nil
// while unmounted.
- (NSString *)mountStateForObject:(DUStorageObject *)object
{
    NSString *point = self.mountPoints[object.identifier];
    if (point != nil) {
        return point;
    }
    DUStorageVolume *inner = [self volumeForObject:object];
    return inner != nil ? self.mountPoints[inner.identifier] : nil;
}

- (void)setMountPoint:(NSString *)point forObjectTree:(DUStorageObject *)object
{
    DUStorageVolume *volume = [self volumeForObject:object];
    NSString *identifier =
        volume != nil ? volume.identifier : object.identifier;
    self.mountPoints[identifier] = point;
    [self applyMountPropsToObjectTree:object];
}

- (void)clearMountStateForObjectTree:(DUStorageObject *)object
{
    [self.mountPoints removeObjectForKey:object.identifier];
    DUStorageVolume *volume = [self volumeForObject:object];
    if (volume != nil) {
        [self.mountPoints removeObjectForKey:volume.identifier];
    }
    [self applyMountPropsToObjectTree:object];
}

// Mirrors the authoritative mount map onto the convenience model properties
// so information panels render without asking the backend again.
- (void)applyMountPropsToObjectTree:(DUStorageObject *)object
{
    DUStorageVolume *volume = [self volumeForObject:object];
    if (volume == nil) {
        return;
    }
    NSString *point = self.mountPoints[volume.identifier];
    volume.mounted = point != nil;
    volume.mountPoint = point;
    volume.capabilities.canMount = point == nil;
    volume.capabilities.canUnmount = point != nil;
}

- (void)forgetMountsUnder:(DUStorageObject *)object
{
    for (DUStorageObject *item in [object flattenObjects]) {
        [self.mountPoints removeObjectForKey:item.identifier];
    }
}

#pragma mark - Image creation

// Simulated device imaging: short stepped progress, no file is written so
// the mock stays safe on any machine.
- (void)createImageFromObject:(DUStorageObject *)object
                      options:(NSDictionary *)options
                     progress:(void (^)(double, NSString *))progress
                   completion:(void (^)(NSError *))completion
{
    NSThread *worker = [[NSThread alloc]
        initWithBlock:^{
            @autoreleasepool {
                NSString *path = options[@"path"];
                if (path.length == 0) {
                    completion(DUErrorMake(DUErrorInvalidArgument,
                                           NSLocalizedString(
                                               @"Missing image parameters.",
                                               nil)));
                    return;
                }
                BOOL (^cancelCheck)(void) = options[@"duCancelCheck"];
                for (int step = 0; step <= 10; step++) {
                    if (cancelCheck != nil && cancelCheck()) {
                        completion(DUErrorMake(DUErrorCancelled,
                                               NSLocalizedString(
                                                   @"Cancelled.", nil)));
                        return;
                    }
                    [NSThread sleepForTimeInterval:0.05];
                    progress(step / 10.0,
                             NSLocalizedString(@"Copying device data...",
                                               nil));
                }
                progress(1.0, NSLocalizedString(
                                  @"Image created successfully.", nil));
                completion(nil);
            }
        }];
    worker.name = @"DU-mock-imaging";
    [worker start];
}

- (NSArray<NSDictionary *> *)imageCreationFormats
{
    /* The mock simulates a system with qemu-img installed, so the
     * conversion targets match what the caps advertise. */
    return @[
        @{ kDUFormatIdentifierKey : @"raw",
           kDUFormatDisplayNameKey :
               NSLocalizedString(@"Raw disk image (.img)", nil) },
        @{ kDUFormatIdentifierKey : @"gz",
           kDUFormatDisplayNameKey :
               NSLocalizedString(@"Gzipped raw image (.img.gz)", nil) },
        @{ kDUFormatIdentifierKey : @"qcow2",
           kDUFormatDisplayNameKey :
               NSLocalizedString(@"QEMU copy-on-write (.qcow2)", nil) },
        @{ kDUFormatIdentifierKey : @"vdi",
           kDUFormatDisplayNameKey :
               NSLocalizedString(@"VirtualBox disk image (.vdi)", nil) },
    ];
}

#pragma mark - Image conversion, resizing, burning (simulated)

- (DUDiskImage *)imageForObject:(DUStorageObject *)object
{
    for (DUStorageObject *root in self.roots) {
        if ([root isKindOfClass:[DUDiskImage class]] &&
            [root.identifier isEqualToString:object.identifier]) {
            return (DUDiskImage *)root;
        }
    }
    return nil;
}

- (void)convertImage:(DUStorageObject *)image
             options:(NSDictionary *)options
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(NSError *))completion
{
    NSString *format = options[@"format"];
    if (format.length == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing image parameters.", nil)));
        return;
    }
    [self spawnWork:^{
        [self simulateSteps:8
                    message:NSLocalizedString(@"Converting image...", nil)
                   progress:progress];
        [self.lock lock];
        DUDiskImage *mockImage = [self imageForObject:image];
        if (mockImage != nil) {
            mockImage.format = format;
            mockImage.compressed = ![format isEqualToString:@"raw"];
        }
        [self.lock unlock];
        progress(1.0,
                 NSLocalizedString(@"Image converted successfully.", nil));
        completion(nil);
    }];
}

- (void)resizeImage:(DUStorageObject *)image
             options:(NSDictionary *)options
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(NSError *))completion
{
    NSNumber *delta = options[@"deltaBytes"];
    if (delta == nil) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing image parameters.", nil)));
        return;
    }
    [self spawnWork:^{
        [self simulateSteps:5
                    message:NSLocalizedString(@"Resizing image...", nil)
                   progress:progress];
        [self.lock lock];
        DUDiskImage *mockImage = [self imageForObject:image];
        if (mockImage != nil) {
            unsigned long long newSize =
                MAX(kMiB, mockImage.sizeBytes + delta.longLongValue);
            mockImage.sizeBytes = newSize;
            if (mockImage.backingVolume != nil) {
                mockImage.backingVolume.capacityBytes = newSize;
                mockImage.backingVolume.availableBytes =
                    newSize - mockImage.backingVolume.usedBytes;
            }
        }
        [self.lock unlock];
        progress(1.0,
                 NSLocalizedString(@"Image resized successfully.", nil));
        completion(nil);
    }];
}

- (void)burnImage:(DUStorageObject *)image
         toObject:(DUStorageObject *)opticalDrive
         progress:(void (^)(double, NSString *))progress
        completion:(void (^)(NSError *))completion
{
    [self spawnWork:^{
        [self simulateSteps:20
                    message:NSLocalizedString(@"Burning image...", nil)
                   progress:progress];
        [self.lock lock];
        for (DUStorageObject *root in self.roots) {
            if (![root isKindOfClass:[DUStorageDevice class]] ||
                !((DUStorageDevice *)root).optical) {
                continue;
            }
            if (![root.identifier isEqualToString:opticalDrive.identifier]) {
                continue;
            }
            for (DUStorageObject *child in root.children) {
                DUOpticalMedia *media = (DUOpticalMedia *)child;
                if (![media isKindOfClass:[DUOpticalMedia class]]) {
                    continue;
                }
                media.displayName =
                    [NSString stringWithFormat:
                         NSLocalizedString(@"Burned: %@",
                                           @"optical disc label"),
                         image.displayName ?: @"image"];
            }
        }
        [self.lock unlock];
        progress(1.0,
                 NSLocalizedString(@"Image burned successfully.", nil));
        completion(nil);
    }];
}

@end
