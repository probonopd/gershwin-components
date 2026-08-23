/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// ObjectTesting coverage for DUPartitionLayout (ARCHITECTURE.md sections
// 43/44): first-fit allocation, grow/shrink into the following gap only,
// scheme limits, validate, and commit/revert baseline semantics. Assertions
// follow the implemented contract in Sources/Models/DUPartitionLayout.m.

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "DUPartitionLayout.h"
#import "DUPartition.h"
#import "DUErrors.h"

static const unsigned long long KiB = 1024ull;
static const unsigned long long MiB = 1024ull * 1024ull;
static const unsigned long long GiB = 1024ull * 1024ull * 1024ull;

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    // ------------------------------------------------------------------
    // Fresh layout state
    // ------------------------------------------------------------------
    DUPartitionLayout *layout =
        [[DUPartitionLayout alloc] initWithCapacity:100ull * GiB
                                             scheme:@"gpt"];
    PASS(layout.capacityBytes == 100ull * GiB, "capacity stored verbatim");
    PASS([layout.scheme isEqualToString:@"gpt"], "scheme token kept");
    PASS(layout.partitions.count == 0, "fresh layout is empty");
    PASS(layout.hasPendingChanges == NO,
         "empty working set matches empty baseline: no pending changes");
    PASS([layout validate:NULL] == YES, "empty layout validates");
    PASS(layout.totalUsedBytes == 0, "nothing used yet");

    // ------------------------------------------------------------------
    // First-fit allocation of 40/30/20 GiB
    // ------------------------------------------------------------------
    BOOL added1 = [layout addPartitionWithSize:40ull * GiB
                                          name:@"first"
                                         error:NULL];
    PASS(added1 == YES, "40 GiB partition added");
    BOOL added2 = [layout addPartitionWithSize:30ull * GiB
                                          name:@"middle"
                                         error:NULL];
    PASS(added2 == YES, "30 GiB partition added");
    BOOL added3 = [layout addPartitionWithSize:20ull * GiB
                                          name:@"last"
                                         error:NULL];
    PASS(added3 == YES, "20 GiB partition added");

    NSArray<DUPartition *> *parts = layout.partitions;
    PASS(parts.count == 3, "three partitions present");

    PASS(parts[0].offsetBytes == 0, "first allocation starts at 0");
    PASS(parts[1].offsetBytes == 40ull * GiB, "second follows contiguously");
    PASS(parts[2].offsetBytes == 70ull * GiB, "third follows contiguously");

    BOOL sizesExact = parts[0].sizeBytes == 40ull * GiB
        && parts[1].sizeBytes == 30ull * GiB
        && parts[2].sizeBytes == 20ull * GiB;
    PASS(sizesExact == YES, "requested sizes stored exactly");

    BOOL contiguous = parts[0].offsetBytes + parts[0].sizeBytes
            <= parts[1].offsetBytes
        && parts[1].offsetBytes + parts[1].sizeBytes
            <= parts[2].offsetBytes;
    PASS(contiguous == YES, "offsets are ordered and non-overlapping");
    PASS([layout validate:NULL] == YES, "filled layout validates");

    BOOL indexesRenumbered =
        parts[0].index == 0 && parts[1].index == 1 && parts[2].index == 2;
    PASS(indexesRenumbered == YES, "indexes renumbered by offset order");
    PASS(layout.totalUsedBytes == 90ull * GiB, "used bytes sum up");
    unsigned long long trailing =
        [layout freeBytesAfterPartition:parts[2]];
    PASS(trailing == 10ull * GiB,
         "trailing free space after last partition reported");

    // ------------------------------------------------------------------
    // No room for a fourth big partition
    // ------------------------------------------------------------------
    NSError *overflowError = nil;
    BOOL overflowAdded = [layout addPartitionWithSize:15ull * GiB
                                                 name:@"extra"
                                                error:&overflowError];
    PASS(overflowAdded == NO,
         "15 GiB does not fit into the 10 GiB trailing gap");
    PASS(overflowError != nil
             && [overflowError.domain isEqual:DUStorageErrorDomain]
             && overflowError.code == DUErrorInvalidArgument,
         "failure surfaced as DUStorageErrorDomain/DUErrorInvalidArgument");
    PASS(layout.partitions.count == 3,
         "failed add leaves the layout untouched");

    // ------------------------------------------------------------------
    // Resize grows/shrinks into the following gap only
    // ------------------------------------------------------------------
    DUPartition *middle = parts[1];
    NSError *growError = nil;
    BOOL grew = [layout resizePartition:middle
                            toSizeBytes:60ull * GiB
                                  error:&growError];
    // Middle ends at 70 GiB where 'last' begins; only 30 GiB of growth room.
    PASS(grew == NO, "growing middle to 60 GiB blocked by next partition");
    PASS(growError != nil
             && [growError.localizedDescription length] > 0,
         "resize failure carries an explanation");
    PASS(middle.sizeBytes == 30ull * GiB,
         "blocked resize leaves size unchanged");

    BOOL shrank = [layout resizePartition:middle
                              toSizeBytes:20ull * GiB
                                    error:NULL];
    PASS(shrank == YES, "shrinking middle leaves a gap");
    unsigned long long gapAfterShrink =
        [layout freeBytesAfterPartition:middle];
    PASS(gapAfterShrink == 10ull * GiB,
         "gap after shrink visible to callers");

    BOOL regrew = [layout resizePartition:middle
                              toSizeBytes:30ull * GiB
                                    error:NULL];
    PASS(regrew == YES, "growing back into own gap works");
    PASS(middle.offsetBytes == 40ull * GiB,
         "resize never moves offsets");

    // ------------------------------------------------------------------
    // Remove and re-add fills the hole again
    // ------------------------------------------------------------------
    DUPartition *last = parts[2];
    BOOL removed = [layout removePartition:last error:NULL];
    PASS(removed == YES, "partition removed");
    PASS(layout.partitions.count == 2, "layout shrunk to two partitions");

    BOOL readded = [layout addPartitionWithSize:25ull * GiB
                                           name:@"replacement"
                                          error:NULL];
    PASS(readded == YES, "re-add fits the freed space");
    NSArray<DUPartition *> *afterReadd = layout.partitions;
    PASS(afterReadd.count == 3, "three partitions after remove + add");
    PASS(afterReadd[2].offsetBytes == 70ull * GiB,
         "new partition placed at first fitting gap start");
    PASS([layout validate:NULL] == YES, "still valid after reshuffle");

    // ------------------------------------------------------------------
    // Commit / pending / revert semantics
    // ------------------------------------------------------------------
    [layout commitAsBaseline];
    PASS(layout.hasPendingChanges == NO, "commit clears dirty state");

    NSString *originalFirstName =
        [[layout.partitions[0].name copy] autorelease];
    [layout renamePartition:layout.partitions[0] toName:@"renamed"];
    PASS(layout.hasPendingChanges == YES,
         "rename marks pending changes");
    PASS([layout.partitions[0].name isEqualToString:@"renamed"],
         "rename took effect on working set");
    [layout revertToCommitted];
    PASS(layout.hasPendingChanges == NO, "revert clears dirty state");
    PASS([layout.partitions[0].name isEqualToString:originalFirstName],
         "revert restores committed name");

    [layout setFormat:@"ext4" forPartition:layout.partitions[1]];
    PASS(layout.hasPendingChanges == YES,
         "pending format marks dirty state");
    PASS([layout.partitions[1].filesystemType isEqualToString:@"ext4"],
         "format recorded on working set");
    [layout revertToCommitted];
    PASS(layout.partitions[1].filesystemType == nil,
         "revert drops uncommitted filesystem type");

    // Structural edits revert to the exact committed geometry.
    unsigned long long wantOffsets[3] = {
        layout.partitions[0].offsetBytes,
        layout.partitions[1].offsetBytes,
        layout.partitions[2].offsetBytes
    };
    unsigned long long wantSizes[3] = {
        layout.partitions[0].sizeBytes,
        layout.partitions[1].sizeBytes,
        layout.partitions[2].sizeBytes
    };
    NSString *wantIdentifiers[3] = {
        layout.partitions[0].identifier,
        layout.partitions[1].identifier,
        layout.partitions[2].identifier
    };
    DUPartition *heldReference = layout.partitions[1];

    [layout removePartition:layout.partitions[0] error:NULL];
    [layout resizePartition:layout.partitions[0]
                toSizeBytes:10ull * GiB
                      error:NULL];
    [layout addPartitionWithSize:5ull * GiB name:@"junk" error:NULL];
    PASS(layout.hasPendingChanges == YES,
         "structural edits mark dirty state");

    [layout revertToCommitted];
    NSArray<DUPartition *> *restored = layout.partitions;
    BOOL geometryRestored = restored.count == 3;
    for (NSUInteger i = 0; geometryRestored && i < 3; i++) {
        geometryRestored = restored[i].offsetBytes == wantOffsets[i]
            && restored[i].sizeBytes == wantSizes[i]
            && [restored[i].identifier isEqualToString:wantIdentifiers[i]];
    }
    PASS(geometryRestored == YES,
         "revert restores count, offsets, sizes and identifiers exactly");
    PASS(restored[1] != heldReference,
         "reverted objects are fresh copies, never aliased with pre-revert "
         "references");
    PASS([restored[1].identifier isEqualToString:heldReference.identifier],
         "lookup by identifier keeps caller references meaningful");
    PASS(layout.hasPendingChanges == NO, "revert returns to clean baseline");

    // ------------------------------------------------------------------
    // Minimum partition size enforcement
    // ------------------------------------------------------------------
    DUPartitionLayout *smallLayout =
        [[DUPartitionLayout alloc] initWithCapacity:1ull * GiB
                                             scheme:@"mbr"];
    NSError *tinyError = nil;
    BOOL tinyAdded = [smallLayout addPartitionWithSize:MiB - KiB
                                                  name:@"tiny"
                                                 error:&tinyError];
    PASS(tinyAdded == NO, "sub-1 MiB partition rejected");
    PASS(tinyError != nil, "minimum-size rejection explains itself");
    BOOL boundaryAdded = [smallLayout addPartitionWithSize:MiB
                                                      name:@"boundary"
                                                     error:NULL];
    PASS(boundaryAdded == YES, "exactly 1 MiB accepted at the floor");

    DUPartition *boundary = smallLayout.partitions[0];
    BOOL shrunkToTiny = [smallLayout resizePartition:boundary
                                         toSizeBytes:KiB
                                               error:NULL];
    PASS(shrunkToTiny == NO, "resize below the minimum rejected");
    PASS(boundary.sizeBytes == MiB, "rejected resize changed nothing");

    // ------------------------------------------------------------------
    // Scheme partition-count limits (bsd: 8)
    // ------------------------------------------------------------------
    DUPartitionLayout *bsdLayout =
        [[DUPartitionLayout alloc] initWithCapacity:4ull * GiB
                                             scheme:@"bsd"];
    BOOL eightOK = YES;
    for (NSUInteger i = 0; i < 8; i++) {
        NSString *label =
            [NSString stringWithFormat:@"p%lu", (unsigned long)i];
        eightOK = eightOK
            && [bsdLayout addPartitionWithSize:16ull * MiB
                                          name:label
                                         error:NULL];
    }
    PASS(eightOK == YES, "eight bsd partitions fit the scheme limit");
    NSError *ninthError = nil;
    BOOL ninthAdded = [bsdLayout addPartitionWithSize:16ull * MiB
                                                 name:@"nine"
                                                error:&ninthError];
    PASS(ninthAdded == NO, "ninth bsd partition rejected by scheme limit");
    PASS(ninthError != nil
             && [ninthError.localizedDescription length] > 0,
         "scheme-limit rejection explains itself");
    PASS(bsdLayout.partitions.count == 8,
         "count stays at the limit after failed add");
    PASS([bsdLayout validate:NULL] == YES,
         "limit-filling layout still validates");

    // ------------------------------------------------------------------
    // Overlap impossible through the public API
    // ------------------------------------------------------------------
    DUPartitionLayout *mbrLayout =
        [[DUPartitionLayout alloc] initWithCapacity:10ull * GiB
                                             scheme:@"mbr"];
    [mbrLayout addPartitionWithSize:3ull * GiB name:@"a" error:NULL];
    [mbrLayout addPartitionWithSize:3ull * GiB name:@"b" error:NULL];
    [mbrLayout addPartitionWithSize:3957ull * MiB name:@"c" error:NULL];
    PASS([mbrLayout validate:NULL] == YES, "packed mbr layout validates");

    BOOL extraAdded = [mbrLayout addPartitionWithSize:1ull * GiB
                                                 name:@"d"
                                                error:NULL];
    PASS(extraAdded == NO, "cannot overfill the disk via add");

    NSArray<DUPartition *> *mbrParts = mbrLayout.partitions;
    DUPartition *tail = mbrParts[2];
    unsigned long long oversized = tail.sizeBytes + 2ull * GiB;
    BOOL tailGrew = [mbrLayout resizePartition:tail
                                   toSizeBytes:oversized
                                         error:NULL];
    PASS(tailGrew == NO, "cannot resize past device end");

    BOOL noOverlap = YES;
    unsigned long long previousEnd = 0;
    for (DUPartition *part in mbrLayout.partitions) {
        noOverlap = noOverlap && part.offsetBytes >= previousEnd
            && part.offsetBytes < mbrLayout.capacityBytes
            && part.sizeBytes <= mbrLayout.capacityBytes - part.offsetBytes;
        previousEnd = part.offsetBytes + part.sizeBytes;
    }
    PASS(noOverlap == YES,
         "every partition starts after its predecessor and fits capacity");
    PASS([mbrLayout validate:NULL] == YES,
         "post-mutation layout validates");

    // ------------------------------------------------------------------
    // Foreign partitions are refused
    // ------------------------------------------------------------------
    DUPartition *stranger =
        [[DUPartition alloc] initWithIdentifier:@"not-in-this-layout"];
    stranger.offsetBytes = 0;
    stranger.sizeBytes = GiB;
    NSError *foreignResizeError = nil;
    BOOL foreignResized = [layout resizePartition:stranger
                                      toSizeBytes:2ull * GiB
                                            error:&foreignResizeError];
    PASS(foreignResized == NO,
         "resizing a partition from another layout fails");
    PASS(foreignResizeError != nil, "foreign resize reports an error");
    PASS([layout freeBytesAfterPartition:stranger] == 0,
         "free space query for unknown partition yields 0");

    [pool release];
    return 0;
}
