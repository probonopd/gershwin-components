/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPartitionPlan.h"

#import "DUPartition.h"
#import "DUPartitionLayout.h"
#import "DUStorageObject.h"

@implementation DUPartitionPlan {
    NSString *_diskIdentifier;
    NSString *_scheme;
    NSArray<DUPartition *> *_entries;
    BOOL _destructive;
}

+ (instancetype)planFromLayout:(DUPartitionLayout *)layout
                    forDevice:(DUStorageObject *)device
                   destructive:(BOOL)destructive
{
    NSParameterAssert(layout != nil);
    NSParameterAssert(device != nil);
    NSParameterAssert(device.identifier.length > 0);
    // A plan is only made from a valid layout; validation happens before
    // Apply per ARCHITECTURE.md sections 43/44, so an invalid layout here
    // is a caller bug and must fail loudly rather than reach a backend.
    NSError *validationError = nil;
    if (![layout validate:&validationError]) {
        [NSException raise:NSInvalidArgumentException
                    format:@"Cannot build partition plan from invalid "
                           @"layout: %@",
                           validationError.localizedDescription];
    }

    NSMutableArray<DUPartition *> *snapshot =
        [NSMutableArray arrayWithCapacity:layout.partitions.count];
    for (DUPartition *partition in layout.partitions) {
        [snapshot addObject:[partition copy]];
    }

    return [[self alloc] _initWithDiskIdentifier:device.identifier
                                          scheme:layout.scheme
                                         entries:snapshot
                                      destructive:destructive];
}

- (instancetype)_initWithDiskIdentifier:(NSString *)diskIdentifier
                                 scheme:(NSString *)scheme
                                entries:(NSArray<DUPartition *> *)entries
                             destructive:(BOOL)destructive
{
    if ((self = [super init]) == nil) {
        return nil;
    }
    _diskIdentifier = [diskIdentifier copy];
    _scheme = [scheme copy];
    _entries = [entries copy];
    _destructive = destructive;
    return self;
}

// Table edits always run privileged, regardless of the destructive flag
// (header contract).
- (BOOL)requiresPrivilege
{
    return YES;
}

@end
