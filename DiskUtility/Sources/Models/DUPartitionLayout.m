/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPartitionLayout.h"

#import "DUPartition.h"
#import "DUErrors.h"

// Minimum partition size accepted anywhere in this model; matches the
// validation floor required by ARCHITECTURE.md section 44.
static const unsigned long long kMinimumPartitionBytes = 1024ull * 1024ull;

static NSInteger SchemePartitionLimit(NSString *scheme)
{
    if ([scheme isEqualToString:@"gpt"]) {
        return 128;
    }
    if ([scheme isEqualToString:@"mbr"]) {
        return 15;
    }
    if ([scheme isEqualToString:@"bsd"]) {
        return 8;
    }
    // Unknown scheme: no count limit can be enforced here; backends still
    // validate before touching a disk.
    return NSNotFound;
}

@implementation DUPartitionLayout {
    NSMutableArray<DUPartition *> *_partitionList;
    NSArray<DUPartition *> *_committedPartitions;
}

- (instancetype)initWithCapacity:(unsigned long long)bytes
                          scheme:(NSString *)schemeIdentifier
{
    NSParameterAssert(bytes > 0);
    if ((self = [super init]) == nil) {
        return nil;
    }
    _capacityBytes = bytes;
    _scheme = [schemeIdentifier copy];
    _partitionList = [NSMutableArray array];
    _committedPartitions = @[];
    return self;
}

- (NSArray<DUPartition *> *)partitions
{
    // Keep offsets ascending after every mutation so callers never sort.
    [_partitionList sortUsingComparator:^NSComparisonResult(DUPartition *a,
                                                            DUPartition *b) {
        if (a.offsetBytes < b.offsetBytes) {
            return NSOrderedAscending;
        }
        if (a.offsetBytes > b.offsetBytes) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    return [_partitionList copy];
}

- (BOOL)hasPendingChanges
{
    // Computed rather than tracked as a flag so the dirty state can never
    // drift from the actual content after revert/commit swaps.
    NSArray<DUPartition *> *current = self.partitions; // also re-sorts in place
    if (current.count != _committedPartitions.count) {
        return YES;
    }
    for (NSUInteger i = 0; i < current.count; i++) {
        DUPartition *now = current[i];
        DUPartition *committed = _committedPartitions[i];
        BOOL differs = now.offsetBytes != committed.offsetBytes
            || now.sizeBytes != committed.sizeBytes
            || now.index != committed.index
            || ![now.name ?: @"" isEqualToString:(committed.name ?: @"")]
            || ![now.filesystemType ?: @"" isEqualToString:(committed.filesystemType ?: @"")];
        if (differs) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Private helpers

// Lookup by identifier, not pointer identity, so caller-held references
// stay meaningful even after revertToCommitted swapped in fresh copies.
- (DUPartition *)layoutPartitionMatching:(DUPartition *)partition
{
    if (partition == nil || partition.identifier.length == 0) {
        return nil;
    }
    for (DUPartition *candidate in _partitionList) {
        if ([candidate.identifier isEqualToString:partition.identifier]) {
            return candidate;
        }
    }
    return nil;
}

- (void)renumberIndexes
{
    [_partitionList enumerateObjectsWithOptions:0
                                     usingBlock:^(DUPartition *partition,
                                                  NSUInteger idx,
                                                  BOOL *stop __attribute__((unused))) {
        partition.index = (NSInteger)idx;
    }];
}

- (unsigned long long)gapStartBeforeIndex:(NSUInteger)index
                                 inSorted:(NSArray<DUPartition *> *)sorted
{
    if (index == 0) {
        return 0;
    }
    DUPartition *previous = sorted[index - 1];
    return previous.offsetBytes + previous.sizeBytes;
}

- (unsigned long long)gapEndAfterIndex:(NSUInteger)index
                              inSorted:(NSArray<DUPartition *> *)sorted
{
    if (index >= sorted.count) {
        return self.capacityBytes;
    }
    return sorted[index].offsetBytes;
}

- (BOOL)setError:(NSError **)error message:(NSString *)message
{
    if (error != NULL) {
        *error = DUErrorMake(DUErrorInvalidArgument, message);
    }
    return NO;
}

#pragma mark - Editing

- (BOOL)addPartitionWithSize:(unsigned long long)sizeBytes
                        name:(NSString *)name
                       error:(NSError **)error
{
    if (sizeBytes < kMinimumPartitionBytes) {
        return [self setError:error
                      message:[NSString stringWithFormat:
                          NSLocalizedString(
                              @"Partition must be at least %llu bytes",
                              @"Partition layout error"),
                          kMinimumPartitionBytes]];
    }

    NSInteger limit = SchemePartitionLimit(_scheme);
    if (limit != NSNotFound && (NSInteger)_partitionList.count >= limit) {
        return [self setError:error
                      message:[NSString stringWithFormat:
                          NSLocalizedString(
                              @"Scheme supports at most %ld partitions",
                              @"Partition layout error"),
                          (long)limit]];
    }

    // First-fit over all gaps in offset order: leading hole, holes between
    // existing partitions, trailing space.
    NSArray<DUPartition *> *sorted = self.partitions;
    unsigned long long gapStart = 0;
    BOOL found = NO;
    for (NSUInteger i = 0; i <= sorted.count && !found; i++) {
        unsigned long long start =
            [self gapStartBeforeIndex:i inSorted:sorted];
        unsigned long long end = [self gapEndAfterIndex:i inSorted:sorted];
        if (start >= end || end - start < sizeBytes ||
            start > _capacityBytes - sizeBytes) {
            continue;
        }
        gapStart = start;
        found = YES;
    }
    if (!found) {
        return [self setError:error
                      message:NSLocalizedString(
                          @"Not enough free space for new partition",
                          @"Partition layout error")];
    }

    NSString *identifier = [[NSUUID UUID] UUIDString];
    DUPartition *partition =
        [[DUPartition alloc] initWithIdentifier:identifier];
    if (partition == nil) {
        return [self setError:error
                      message:NSLocalizedString(@"Could not create partition",
                                                @"Partition layout error")];
    }
    partition.name = name;
    partition.displayName = name != nil ? name : identifier;
    partition.offsetBytes = gapStart;
    partition.sizeBytes = sizeBytes;

    [_partitionList addObject:partition];
    [self renumberIndexes];
    return YES;
}

- (BOOL)removePartition:(DUPartition *)partition error:(NSError **)error
{
    DUPartition *existing = [self layoutPartitionMatching:partition];
    if (existing == nil) {
        return [self setError:error
                      message:NSLocalizedString(
                          @"Partition is not part of this layout",
                          @"Partition layout error")];
    }
    [_partitionList removeObject:existing];
    [self renumberIndexes];
    return YES;
}

- (BOOL)resizePartition:(DUPartition *)partition
             toSizeBytes:(unsigned long long)newSizeBytes
                   error:(NSError **)error
{
    DUPartition *existing = [self layoutPartitionMatching:partition];
    if (existing == nil) {
        return [self setError:error
                      message:NSLocalizedString(
                          @"Partition is not part of this layout",
                          @"Partition layout error")];
    }
    if (newSizeBytes < kMinimumPartitionBytes) {
        return [self setError:error
                      message:[NSString stringWithFormat:
                          NSLocalizedString(
                              @"Partition must be at least %llu bytes",
                              @"Partition layout error"),
                          kMinimumPartitionBytes]];
    }

    // Grow/shrink into the following gap only; offsets never move and
    // neighbours are never displaced.
    NSArray<DUPartition *> *sorted = self.partitions;
    NSUInteger position = [sorted indexOfObject:existing];
    // Gap boundaries are numbered by the elements before them, so the gap
    // following 'position' ends at boundary position + 1 (capacity when the
    // partition is the last one).
    unsigned long long availableEnd =
        [self gapEndAfterIndex:position + 1 inSorted:sorted];
    unsigned long long offset = existing.offsetBytes;
    if (offset >= availableEnd || newSizeBytes > availableEnd - offset) {
        return [self setError:error
                      message:NSLocalizedString(@"New size exceeds available space",
                                                @"Partition layout error")];
    }
    existing.sizeBytes = newSizeBytes;
    return YES;
}

- (void)renamePartition:(DUPartition *)partition toName:(NSString *)name
{
    DUPartition *existing = [self layoutPartitionMatching:partition];
    NSParameterAssert(existing != nil);
    if (existing == nil) {
        return;
    }
    existing.name = name;
    // Display name tracks the table label while editing; the backend
    // persists it as the partition name.
    existing.displayName = name;
}

- (void)setFormat:(NSString *)filesystemType forPartition:(DUPartition *)partition
{
    DUPartition *existing = [self layoutPartitionMatching:partition];
    NSParameterAssert(existing != nil);
    if (existing == nil) {
        return;
    }
    existing.filesystemType = filesystemType;
}

#pragma mark - Queries

- (unsigned long long)freeBytesAfterPartition:(DUPartition *)partition
{
    DUPartition *existing = [self layoutPartitionMatching:partition];
    if (existing == nil) {
        return 0;
    }
    NSArray<DUPartition *> *sorted = self.partitions;
    NSUInteger position = [sorted indexOfObject:existing];
    // Boundary position + 1 marks the start of the next partition, or the
    // device end when this is the last one (see resizePartition).
    unsigned long long nextStart =
        [self gapEndAfterIndex:position + 1 inSorted:sorted];
    unsigned long long end = existing.offsetBytes + existing.sizeBytes;
    if (end >= nextStart) {
        return 0;
    }
    return nextStart - end;
}

- (unsigned long long)totalUsedBytes
{
    unsigned long long total = 0;
    for (DUPartition *partition in _partitionList) {
        total += partition.sizeBytes;
    }
    return total;
}

- (BOOL)validate:(NSError **)error
{
    NSArray<DUPartition *> *sorted = self.partitions;
    NSInteger limit = SchemePartitionLimit(_scheme);
    if (limit != NSNotFound && (NSInteger)sorted.count > limit) {
        return [self setError:error
                      message:[NSString stringWithFormat:
                          NSLocalizedString(
                              @"Scheme supports at most %ld partitions",
                              @"Partition layout error"),
                          (long)limit]];
    }

    unsigned long long previousEnd = 0;
    for (DUPartition *partition in sorted) {
        if (partition.sizeBytes < kMinimumPartitionBytes) {
            return [self setError:error
                          message:[NSString stringWithFormat:
                              NSLocalizedString(
                                  @"Partition must be at least %llu bytes",
                                  @"Partition layout error"),
                              kMinimumPartitionBytes]];
        }
        if (partition.offsetBytes > _capacityBytes ||
            partition.sizeBytes > _capacityBytes - partition.offsetBytes) {
            return [self setError:error
                          message:NSLocalizedString(
                              @"Layout does not fit device capacity",
                              @"Partition layout error")];
        }
        unsigned long long start = partition.offsetBytes;
        unsigned long long end = start + partition.sizeBytes;
        if (start < previousEnd) {
            return [self setError:error
                          message:NSLocalizedString(
                              @"Partitions must not overlap",
                              @"Partition layout error")];
        }
        previousEnd = end;
    }
    return YES;
}

#pragma mark - Baseline

- (void)commitAsBaseline
{
    NSMutableArray<DUPartition *> *snapshot =
        [NSMutableArray arrayWithCapacity:_partitionList.count];
    for (DUPartition *partition in _partitionList) {
        [snapshot addObject:[partition copy]];
    }
    _committedPartitions = snapshot;
}

- (void)revertToCommitted
{
    // Fresh copies again: working set and baseline must never alias objects,
    // otherwise later edits would corrupt the committed state silently.
    NSMutableArray<DUPartition *> *restored =
        [NSMutableArray arrayWithCapacity:_committedPartitions.count];
    for (DUPartition *partition in _committedPartitions) {
        [restored addObject:[partition copy]];
    }
    _partitionList = restored;
    [self renumberIndexes];
}

@end
