/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// ObjectTesting coverage for the Wave-1 domain models:
// DUStorageCapabilities, the DUStorageObject tree, DUPartition's deep
// value copy, and DUPartitionPlan snapshot independence.

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "DUStorageCapabilities.h"
#import "DUStorageObject.h"
#import "DUStorageDevice.h"
#import "DUPartition.h"
#import "DUStorageVolume.h"
#import "DUPartitionLayout.h"
#import "DUPartitionPlan.h"

static const unsigned long long GiB = 1024ull * 1024ull * 1024ull;

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    // ------------------------------------------------------------------
    // DUStorageCapabilities defaults and bulk setters
    // ------------------------------------------------------------------
    {
        DUStorageCapabilities *caps = [[DUStorageCapabilities alloc] init];
        BOOL allDefaultNo = caps.canVerify == NO && caps.canRepair == NO
            && caps.canErase == NO && caps.canPartition == NO
            && caps.canResize == NO && caps.canMount == NO
            && caps.canUnmount == NO && caps.canEject == NO
            && caps.canBurn == NO && caps.canCreateImage == NO
            && caps.canRestore == NO && caps.canCreateRAID == NO
            && caps.canRepairPermissions == NO
            && caps.canConvertImage == NO && caps.canResizeImage == NO
            && caps.canToggleJournaling == NO;
        PASS(allDefaultNo == YES,
             "every capability defaults to NO per section 16");

        [caps setAllCapabilities:YES];
        BOOL allYes = caps.canVerify && caps.canRepair && caps.canErase
            && caps.canPartition && caps.canResize && caps.canMount
            && caps.canUnmount && caps.canEject && caps.canBurn
            && caps.canCreateImage && caps.canRestore
            && caps.canCreateRAID && caps.canRepairPermissions
            && caps.canConvertImage && caps.canResizeImage
            && caps.canToggleJournaling;
        PASS(allYes == YES, "setAllCapabilities:YES turns every flag on");

        DUStorageCapabilities *factory =
            [DUStorageCapabilities capabilitiesWithAll:NO];
        PASS(factory.canVerify == NO && factory.canBurn == NO,
             "factory-built all-NO holder stays clean");

        [caps setAllCapabilities:NO];
        PASS(caps.canVerify == NO && caps.canToggleJournaling == NO,
             "setAllCapabilities:NO resets every flag");
    }

    // ------------------------------------------------------------------
    // Storage tree: addChild / objectForIdentifier / flatten
    // ------------------------------------------------------------------
    {
        DUStorageDevice *device =
            [[DUStorageDevice alloc] initWithIdentifier:@"disk0"];
        device.displayName = @"System Disk";

        DUPartition *part1 =
            [[DUPartition alloc] initWithIdentifier:@"disk0s1"];
        DUPartition *part2 =
            [[DUPartition alloc] initWithIdentifier:@"disk0s2"];
        DUStorageVolume *volume =
            [[DUStorageVolume alloc] initWithIdentifier:@"disk0s1v"];

        [part1 addChild:volume];
        [device addChild:part1];
        [device addChild:part2];

        PASS(device.children.count == 2, "device holds two children");
        PASS(part1.parent == device,
             "addChild links the weak parent pointer");
        PASS(volume.parent == part1, "grandchild parent points at partition");

        DUStorageObject *found =
            [device objectForIdentifier:@"disk0s1v"];
        PASS(found == volume,
             "depth-first lookup reaches grandchildren");
        PASS([device objectForIdentifier:@"missing"] == nil,
             "unknown identifier yields nil");
        PASS([device objectForIdentifier:@"disk0"] == device,
             "lookup includes self");

        NSArray *flat = [device flattenObjects];
        NSArray *wantOrder =
            @[ @"disk0", @"disk0s1", @"disk0s1v", @"disk0s2" ];
        NSMutableArray *gotOrder = [NSMutableArray array];
        for (DUStorageObject *object in flat) {
            [gotOrder addObject:object.identifier];
        }
        PASS([gotOrder isEqualToArray:wantOrder],
             "flatten walks self then descendants pre-order");

        [device removeChild:part2];
        PASS(device.children.count == 1, "removeChild drops the child");
        PASS(part2.parent == nil,
             "removed child no longer points at its parent");

        // identifier stays authoritative across rebuilds; displayName is
        // presentation only and must never be matched.
        PASS([device objectForIdentifier:@"System Disk"] == nil,
             "lookup matches identifier, not display name");
    }

    // ------------------------------------------------------------------
    // DUPartition copyWithZone is a deep field copy
    // ------------------------------------------------------------------
    {
        DUStorageVolume *volume =
            [[DUStorageVolume alloc] initWithIdentifier:@"vol0"];
        DUPartition *original =
            [[DUPartition alloc] initWithIdentifier:@"p0"];
        original.displayName = @"Original";
        original.backendPath = @"/dev/sda1";
        original.index = 3;
        original.offsetBytes = 40ull * GiB;
        original.sizeBytes = 1ull * GiB;
        original.partitionType = @"linux-data";
        original.name = @"root";
        original.filesystemType = @"ext4";
        original.bootable = YES;
        original.readOnly = YES;
        original.volume = volume;

        DUPartition *copy = [original copyWithZone:nil];
        PASS(copy != nil && copy != original, "copy returns a new object");
        PASS([copy.identifier isEqualToString:@"p0"],
             "identifier carried over");

        BOOL fieldsCopied =
            [copy.displayName isEqualToString:@"Original"]
            && [copy.backendPath isEqualToString:@"/dev/sda1"]
            && copy.index == 3
            && copy.offsetBytes == 40ull * GiB
            && copy.sizeBytes == 1ull * GiB
            && [copy.partitionType isEqualToString:@"linux-data"]
            && [copy.name isEqualToString:@"root"]
            && [copy.filesystemType isEqualToString:@"ext4"]
            && copy.bootable == YES && copy.readOnly == YES;
        PASS(fieldsCopied == YES,
             "all scalar and string fields copied by value");

        original.displayName = @"Changed";
        original.index = 9;
        original.offsetBytes = 999;
        original.sizeBytes = 999;
        original.partitionType = @"other";
        original.name = @"other-name";
        original.filesystemType = @"btrfs";
        original.bootable = NO;
        original.readOnly = NO;
        BOOL immuneToMutation =
            [copy.displayName isEqualToString:@"Original"]
            && copy.index == 3
            && copy.offsetBytes == 40ull * GiB
            && copy.sizeBytes == 1ull * GiB
            && [copy.partitionType isEqualToString:@"linux-data"]
            && [copy.name isEqualToString:@"root"]
            && [copy.filesystemType isEqualToString:@"ext4"]
            && copy.bootable == YES && copy.readOnly == YES;
        PASS(immuneToMutation == YES,
             "mutating the original never leaks into the copy");

        PASS(copy.volume == volume,
             "volume kept as reference: a copy is the same logical "
             "partition, not a filesystem clone (documented behavior)");
    }

    // ------------------------------------------------------------------
    // DUPartitionPlan snapshots are independent of the layout
    // ------------------------------------------------------------------
    {
        DUPartitionLayout *layout =
            [[DUPartitionLayout alloc] initWithCapacity:100ull * GiB
                                                 scheme:@"gpt"];
        [layout addPartitionWithSize:30ull * GiB name:@"alpha" error:NULL];
        [layout addPartitionWithSize:70ull * GiB name:@"beta" error:NULL];

        DUStorageDevice *device =
            [[DUStorageDevice alloc] initWithIdentifier:@"disk9"];

        DUPartitionPlan *plan = [DUPartitionPlan planFromLayout:layout
                                                      forDevice:device
                                                     destructive:NO];
        PASS([plan.diskIdentifier isEqualToString:@"disk9"],
             "plan records the target disk identifier");
        PASS([plan.scheme isEqualToString:@"gpt"], "plan records scheme");
        PASS(plan.destructive == NO, "non-destructive plan flagged as such");
        PASS(plan.requiresPrivilege == YES,
             "table edits always require privilege");

        PASS(plan.entries.count == 2, "plan snapshots both partitions");
        BOOL entriesMatch =
            plan.entries[0].offsetBytes == 0
            && plan.entries[0].sizeBytes == 30ull * GiB
            && [plan.entries[0].name isEqualToString:@"alpha"]
            && plan.entries[1].offsetBytes == 30ull * GiB
            && plan.entries[1].sizeBytes == 70ull * GiB
            && [plan.entries[1].name isEqualToString:@"beta"];
        PASS(entriesMatch == YES,
             "snapshot geometry matches the layout at plan time");

        DUPartition *plannedBeta = plan.entries[1];

        // Mutate everything after planning; the plan must not notice.
        [layout renamePartition:layout.partitions[0] toName:@"gamma"];
        [layout resizePartition:layout.partitions[1]
                    toSizeBytes:10ull * GiB
                          error:NULL];
        [layout removePartition:layout.partitions[0] error:NULL];
        [layout addPartitionWithSize:5ull * GiB name:@"delta" error:NULL];

        BOOL planUnaffected = plan.entries.count == 2
            && [plan.entries[0].name isEqualToString:@"alpha"]
            && plan.entries[1].sizeBytes == 70ull * GiB
            && plan.entries[1].offsetBytes == 30ull * GiB;
        PASS(planUnaffected == YES,
             "later layout mutations leave the plan untouched");
        PASS(plannedBeta.sizeBytes == 70ull * GiB,
             "entries are private copies, not live layout objects");

        DUPartitionPlan *destructivePlan =
            [DUPartitionPlan planFromLayout:layout
                                  forDevice:device
                                 destructive:YES];
        PASS(destructivePlan.destructive == YES,
             "destructive flag propagated into the plan");
        PASS(destructivePlan.entries.count == 2,
             "plan rebuilt from the mutated layout reflects it");
    }

    [pool release];
    return 0;
}
