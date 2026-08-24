#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DUErrors.h"
#import "DUStorageBackend.h"
#import "DUMockStorageBackend.h"
#import "DUBackendFactory.h"
#import "DUPartitionPlan.h"
#import "DUPartitionLayout.h"
#import "DUPartition.h"
#import "DUStorageVolume.h"
#import "DUStorageDevice.h"
#import "DUDiskImage.h"
#import "DUOpticalMedia.h"
#import "DURAIDSet.h"

static volatile int done = 0;

int main(void)
{
    @autoreleasepool {
        NSError *err = nil;
        id<DUStorageBackend> backend = [[DUMockStorageBackend alloc] init];

        NSArray *roots = [backend discoverStorageObjects:&err];
        PASS(roots.count == 5 && err == nil, "discover returns 5 roots");
        PASS([[[backend capabilitiesReport] objectForKey:@"Platform"] isKindOfClass:[NSString class]],
             "capabilitiesReport has Platform string");

        DUStorageDevice *internal = roots[0];
        PASS([internal.identifier isEqualToString:@"mock-disk-internal"], "stable id internal");
        PASS(internal.children.count == 3, "internal has 3 partitions");
        DUPartition *sysPart = (DUPartition *)internal.children[0];
        DUStorageVolume *sysVol = sysPart.volume;
        PASS(sysVol.mounted && [sysVol.mountPoint isEqualToString:@"/"], "system mounted at /");
        PASS([internal.displayName containsString:@"GB"] || [internal.displayName containsString:@"GiB"]
             || [internal.displayName containsString:@"B"], "displayName human size");

        // supportsOperation gating
        PASS([backend supportsOperation:kDUOperationPartition forObject:internal], "device supports partition");
        PASS([backend supportsOperation:kDUOperationUnmount forObject:sysVol], "system volume offers unmount while mounted");
        PASS(![backend supportsOperation:kDUOperationMount forObject:sysVol], "mounted volume hides mount");
        PASS(![backend supportsOperation:@"bogus" forObject:sysVol], "unknown op rejected");

        // supportedFormats
        NSArray *formats = [backend supportedFormatsForObject:sysVol];
        PASS(formats.count == 7, "7 formats offered");
        PASS([[formats.firstObject objectForKey:kDUFormatIdentifierKey] isEqualToString:@"ext4"],
             "format identifier key");

        // mount/unmount Data volume
        DUPartition *dataPart = (DUPartition *)internal.children[1];
        done = 0;
        [backend mountObject:dataPart completion:^(NSError *e, NSString *mp) {
            PASS(e == nil && [mp hasPrefix:@"/Volumes/Data"], "mount data volume");
            done = 1;
        }];
        while (!done) { [NSThread sleepForTimeInterval:0.01]; }
        done = 0;
        [backend unmountObject:dataPart completion:^(NSError *e) {
            PASS(e == nil, "unmount data volume");
            done = 1;
        }];
        while (!done) { [NSThread sleepForTimeInterval:0.01]; }

        // verify happy path with progress
        __block double lastProgress = 0;
        done = 0;
        [backend verifyObject:sysVol progress:^(double p, NSString *m) {
            lastProgress = p;
            (void)m;
        } completion:^(NSError *e) {
            PASS(e == nil && lastProgress > 0.99, "verify success reaches p=1");
            done = 1;
        }];
        while (!done) { [NSThread sleepForTimeInterval:0.01]; }

        // erase with format change
        NSDictionary *opts = @{ kDUFormatIdentifierKey : @"vfat",
                                kDUEraseSecurityMethodKey : kDUEraseMethodZerosKey };
        done = 0;
        [backend eraseObject:dataPart options:opts progress:nil completion:^(NSError *e) {
            PASS(e == nil, "erase succeeds");
            PASS([dataPart.volume.filesystemType isEqualToString:@"vfat"], "erase applies new fstype");
            PASS(!dataPart.volume.mounted && dataPart.volume.usedBytes == 0, "erase blanks volume");
            done = 1;
        }];
        while (!done) { [NSThread sleepForTimeInterval:0.01]; }

        // partition apply from a real DUPartitionPlan
        unsigned long long cap = internal.capacityBytes;
        DUPartitionLayout *layout =
            [[DUPartitionLayout alloc] initWithCapacity:cap scheme:@"gpt"];
        NSError *lerr = nil;
        [layout addPartitionWithSize:cap / 2 name:@"Alpha" error:&lerr];
        [layout addPartitionWithSize:cap / 2 - 2 * 1024 * 1024
                                name:@"Beta" error:&lerr];
        [layout setFormat:@"ext4"
           forPartition:layout.partitions.firstObject];
        DUPartitionPlan *plan =
            [DUPartitionPlan planFromLayout:layout forDevice:internal destructive:YES];
        PASS(plan != nil && plan.entries.count == 2, "plan built from layout");
        done = 0;
        [backend partitionDevice:internal withPlan:plan progress:nil completion:^(NSError *e) {
            PASS(e == nil, "partition apply succeeds");
            PASS(internal.children.count == 2 &&
                 ((DUPartition *)internal.children[0]).volume.filesystemType,
                 "children replaced per plan with fresh volumes");
            done = 1;
        }];
        while (!done) { [NSThread sleepForTimeInterval:0.01]; }

        // eject optical media then refresh restores
        DUStorageDevice *drive = roots[2];
        DUOpticalMedia *media = (DUOpticalMedia *)drive.children.firstObject;
        done = 0;
        [backend ejectObject:media completion:^(NSError *e) {
            PASS(e == nil, "eject disc");
            done = 1;
        }];
        while (!done) { [NSThread sleepForTimeInterval:0.01]; }
        PASS(drive.children.count == 0 && !drive.mediaPresent, "drive empty after eject");
        [(DUMockStorageBackend *)backend restoreHierarchy];
        PASS(((DUMockStorageBackend *)backend).rootObjects.count == 5, "refresh restores hierarchy");

        // degraded backend
        id<DUStorageBackend> degraded = [DUMockStorageBackend degradedBackend];
        NSError *derr = nil;
        PASS([degraded discoverStorageObjects:&derr] == nil &&
             derr.code == DUErrorDiscoveryFailed, "degraded discovery fails clearly");
        PASS([[degraded capabilitiesReport] objectForKey:@"Secure erase"] &&
             [[[degraded capabilitiesReport] objectForKey:@"Secure erase"] isEqualToString:@"no"],
             "degraded report all no");
        PASS(![degraded supportsOperation:kDUOperationErase forObject:sysVol],
             "degraded rejects ops");

        // factory honors a per-process --mock argument and never returns nil
        // on this Linux box (the forcing must not touch persistent defaults)
        NSError *ferr = nil;
        id<DUStorageBackend> forced =
            [DUBackendFactory backendForArguments:@[ @"DiskUtility", @"--mock" ]
                                            error:&ferr];
        PASS(forced != nil && ferr == nil, "forced mock, no error");
        PASS([forced isKindOfClass:[DUMockStorageBackend class]],
             "forced --mock yields the mock backend");

        id<DUStorageBackend> chosen = [DUBackendFactory backendWithError:&ferr];
        PASS(chosen != nil, "factory never returns nil");
    }
    // PASS()/FAIL() from Testing.h already produced the tally.
    return 0;
}
