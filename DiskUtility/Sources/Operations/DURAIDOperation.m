/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DURAIDOperation.h"

#import "DUAuthorizationManager.h"
#import "DUErrors.h"
#import "DUProcessRunner.h"

// Canonical level tokens accepted by -initWithBackend:level:name:members:.
static NSString *const RAIDLevelStripe  = @"stripe";
static NSString *const RAIDLevelMirror  = @"mirror";
static NSString *const RAIDLevelConcat  = @"concat";
static NSString *const RAIDLevelRaid5   = @"raid5";
static NSString *const RAIDLevelRaid10  = @"raid10";

@implementation DURAIDOperation {
    __weak id<DUStorageBackend> _backend;
}

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                          level:(NSString *)level
                           name:(NSString *)name
                        members:(NSArray<DUStorageObject *> *)members
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(level.length > 0);
    NSParameterAssert(name.length > 0);
    NSParameterAssert(members.count > 0);
    if ((self = [super initWithPrimaryObject:members.firstObject]) == nil) {
        return nil;
    }
    _backend = backend;
    _level = [[self normalizedLevel:level] copy];
    if (_level == nil) {
        [NSException raise:NSInvalidArgumentException
                    format:@"unknown RAID level %@", level];
    }
    _name = [name copy];
    _members = [members copy];
    return self;
}

// Accepts the common spellings so UI code can pass what its popup shows;
// runs once per operation construction so no caching is needed.
- (NSString *)normalizedLevel:(NSString *)raw
{
    NSDictionary<NSString *, NSString *> *aliases = @{
        @"0" : RAIDLevelStripe,      @"stripe" : RAIDLevelStripe,
        @"1" : RAIDLevelMirror,      @"mirror" : RAIDLevelMirror,
        @"linear" : RAIDLevelConcat, @"concat" : RAIDLevelConcat,
        @"5" : RAIDLevelRaid5,       @"raid5" : RAIDLevelRaid5,
        @"10" : RAIDLevelRaid10,     @"raid10" : RAIDLevelRaid10,
    };
    return aliases[raw.lowercaseString];
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:NSLocalizedString(@"Create %@ %@", nil),
                     _level, _name];
}

- (NSString *)memberCountRequirementForLevel:(NSString *)level
{
    // Returns nil when the member list satisfies the level.
    NSUInteger count = _members.count;
    BOOL ok;
    if ([level isEqualToString:RAIDLevelConcat]) {
        ok = count >= 1;
    } else if ([level isEqualToString:RAIDLevelRaid10]) {
        ok = count >= 4 && count % 2 == 0;
    } else if ([level isEqualToString:RAIDLevelRaid5]) {
        ok = count >= 3;
    } else {
        ok = count >= 2;
    }
    return ok ? nil
              : [NSString stringWithFormat:@"level %@ needs a different "
                        @"number of members than %lu", level, (unsigned long)count];
}

- (void)execute
{
    if ([self cancelRequested]) {
        [self finishWithError:DUErrorMake(DUErrorCancelled, @"Cancelled before start")];
        return;
    }
    [self setProgress:0.05
              message:NSLocalizedString(@"Validating RAID parameters", nil)];

    NSString *why = [self memberCountRequirementForLevel:_level];
    if (why != nil) {
        [self finishWithError:DUErrorMake(DUErrorInvalidArgument, why)];
        return;
    }

    NSArray<NSString *> *args = [self toolArguments];
    if (args == nil) {
        [self finishWithError:
            DUErrorMake(DUErrorUnsupportedOperation,
                        [NSString stringWithFormat:@"level %@ is unavailable on this platform",
                                                   _level])];
        return;
    }
    NSString *tool = args.firstObject;
    NSArray<NSString *> *toolArgs =
        [args subarrayWithRange:NSMakeRange(1, args.count - 1)];

    [self setProgress:0.5
              message:NSLocalizedString(@"Creating RAID set", nil)];
    NSError *error = nil;
    DUProcessResult *result =
        [[DUAuthorizationManager sharedManager] runPrivileged:tool
                                                         args:toolArgs
                                                      timeout:600.0
                                                        error:&error];
    if (result == nil) {
        [self finishWithError:error ?: DUErrorMake(DUErrorUnknown,
                                                   @"RAID tool could not run")];
        return;
    }
    if ([self cancelRequested]) {
        [self finishWithError:DUErrorMake(DUErrorCancelled, @"Cancelled during creation")];
        return;
    }
    if (!(result.exitedNormally && result.terminationStatus == 0)) {
        NSString *detail = result.standardError.length > 0
            ? result.standardError
            : NSLocalizedString(@"RAID creation failed", nil);
        [self finishWithError:DUErrorMake(DUErrorUnknown, detail)];
        return;
    }

    [self setProgress:1.0 message:NSLocalizedString(@"RAID set created", nil)];
    [self finishWithError:nil];
}

// First element is the executable path, the rest are arguments; nil means
// the platform/level combination has no supported tool.
- (NSArray<NSString *> *)toolArguments
{
    NSMutableArray<NSString *> *paths =
        [NSMutableArray arrayWithCapacity:_members.count];
    for (DUStorageObject *member in _members) {
        NSString *node = member.backendPath;
        if (node.length == 0) {
            return nil; // Fail hard rather than build a half-specified array.
        }
        [paths addObject:node];
    }
#if defined(__linux__)
    NSUInteger count = paths.count;
    // mdadm levels are numeric; /dev/md/<name> keeps the set addressable by
    // name without depending on a particular md minor number.
    NSString *mdLevel;
    if ([_level isEqualToString:RAIDLevelStripe])       { mdLevel = @"0"; }
    else if ([_level isEqualToString:RAIDLevelMirror])  { mdLevel = @"1"; }
    else if ([_level isEqualToString:RAIDLevelRaid5])   { mdLevel = @"5"; }
    else if ([_level isEqualToString:RAIDLevelRaid10])  { mdLevel = @"10"; }
    else { mdLevel = @"linear"; } // concat

    return [@[
        @"/sbin/mdadm",
        @"--create",
        [NSString stringWithFormat:@"/dev/md/%@", _name],
        @"--run",
        @"--level", mdLevel,
        @"--raid-devices", [NSString stringWithFormat:@"%lu", (unsigned long)count],
    ] arrayByAddingObjectsFromArray:paths];

#elif defined(__FreeBSD__)
    // GEOM gate classes cover the common levels; raid5/10 have no stable
    // class and are rejected as unsupported instead of approximated.
    NSString *tool;
    if ([_level isEqualToString:RAIDLevelMirror])          { tool = @"/sbin/gmirror"; }
    else if ([_level isEqualToString:RAIDLevelStripe])     { tool = @"/sbin/gstripe"; }
    else if ([_level isEqualToString:RAIDLevelConcat])     { tool = @"/sbin/gconcat"; }
    else { return nil; }

    return [@[
        tool,
        @"label",
        @"-h", // Keep provider names stable across reboots.
        _name,
    ] arrayByAddingObjectsFromArray:paths];

#else
    // raidctl wants a generated config file per set; that belongs in a real
    // backend wave, so report the gap honestly here.
    (void)paths;
    return nil;
#endif
}

@end
