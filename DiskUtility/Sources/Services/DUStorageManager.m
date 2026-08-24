/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageManager.h"

#import "DUErrors.h"
#import "DUNotifications.h"
#import "DUCreateImageOperation.h"
#import "DUOperation.h"
#import "DUOperationManager.h"
#import "DUStorageBackend.h"
#import "DURepairOperation.h"
#import "DUVerifyOperation.h"

// Per-operation UI callbacks registered by the convenience starters.
@interface DUCallbackPair : NSObject
@property (nonatomic, copy) void (^progress)(double progress, NSString *message);
@property (nonatomic, copy) void (^completion)(NSError *error);
@end
@implementation DUCallbackPair
@end

@implementation DUStorageManager {
    NSLock *_lock;
    id<DUStorageBackend> _backend;
    DUOperationManager *_operationManager;
    NSArray<DUStorageObject *> *_currentObjects;
    NSMutableSet<NSString *> *_busyIdentifiers;

    // operation identifier -> locked resource identifier, so finished
    // operations release exactly the lock they acquired.
    NSMutableDictionary<NSString *, NSString *> *_operationLocks;
    // operation identifier -> UI callbacks for started convenience ops.
    NSMutableDictionary<NSString *, DUCallbackPair *> *_operationCallbacks;
}

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                operationManager:(DUOperationManager *)operationManager
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(operationManager != nil);
    if ((self = [super init]) == nil) {
        return nil;
    }
    _lock = [[NSLock alloc] init];
    _backend = backend;
    _operationManager = operationManager;
    _currentObjects = @[];
    _busyIdentifiers = [NSMutableSet set];
    _operationLocks = [NSMutableDictionary dictionary];
    _operationCallbacks = [NSMutableDictionary dictionary];

    // One permanent observer handles lock release and callback forwarding
    // for every operation; no per-op observer churn.
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidStartNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidUpdateNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidFinishNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidFailNotification
             object:nil];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (id<DUStorageBackend>)backend
{
    return _backend;
}

- (DUOperationManager *)operationManager
{
    return _operationManager;
}

// --- Snapshot ------------------------------------------------------------

- (NSArray<DUStorageObject *> *)currentObjects
{
    [_lock lock];
    NSArray *snapshot = [_currentObjects copy];
    [_lock unlock];
    return snapshot;
}

- (DUStorageObject *)objectForIdentifier:(NSString *)identifier
{
    if (identifier.length == 0) {
        return nil;
    }
    for (DUStorageObject *root in self.currentObjects) {
        DUStorageObject *hit = [root objectForIdentifier:identifier];
        if (hit != nil) {
            return hit;
        }
    }
    return nil;
}

- (DUStorageCapabilities *)capabilitiesForObject:(DUStorageObject *)object
{
    // The model carries per-object capabilities; the platform-wide backend
    // report is exposed separately via -backendCapabilitiesReport.
    return object.capabilities;
}

- (NSDictionary *)backendCapabilitiesReport
{
    return [_backend capabilitiesReport];
}

// --- Refresh / reconcile -------------------------------------------------

// Structural comparison keyed by stable identifiers; enough to spot
// additions, removals and metadata changes without deep value semantics.
- (BOOL)differsFromSnapshot:(NSArray<DUStorageObject *> *)fresh
{
    NSArray<DUStorageObject *> *old = _currentObjects;
    if (old.count != fresh.count) {
        return YES;
    }
    NSMutableDictionary<NSString *, DUStorageObject *> *byId =
        [NSMutableDictionary dictionaryWithCapacity:fresh.count];
    for (DUStorageObject *object in fresh) {
        byId[object.identifier] = object;
    }
    for (DUStorageObject *previous in old) {
        DUStorageObject *next = byId[previous.identifier];
        if (next == nil) {
            return YES;
        }
        if (previous.type != next.type ||
            ![previous.displayName isEqualToString:next.displayName] ||
            !(previous.backendPath == next.backendPath ||
              [previous.backendPath isEqualToString:next.backendPath]) ||
            previous.children.count != next.children.count) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)refreshWithError:(NSError **)error
{
    NSError *discoveryError = nil;
    NSArray *discovered = [_backend discoverStorageObjects:&discoveryError];
    if (discovered == nil) {
        if (error != nil) {
            *error = discoveryError ?:
                DUErrorMake(DUErrorDiscoveryFailed,
                            NSLocalizedString(@"Discovery failed", nil));
        }
        return NO;
    }

    [_lock lock];
    BOOL changed = [self differsFromSnapshot:discovered];
    _currentObjects = [discovered copy];
    [_lock unlock];

    if (changed) {
        // One coarse signal keeps controllers simple; they re-read the
        // snapshot instead of tracking incremental deltas. Observers drive
        // AppKit while callers refresh from worker threads (device monitor,
        // operation completion), so delivery must happen on the main
        // thread or the UI corrupts sporadically.
        [self performSelectorOnMainThread:@selector(postTopologyDidChange)
                               withObject:nil
                            waitUntilDone:NO];
    }
    return YES;
}

// Main-thread continuation of refreshWithError:; observers touch views.
- (void)postTopologyDidChange
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:DUStorageTopologyDidChangeNotification
                      object:self];
}

// --- Busy locks ----------------------------------------------------------

- (BOOL)isBusyIdentifier:(NSString *)identifier
{
    [_lock lock];
    BOOL busy = [_busyIdentifiers containsObject:identifier];
    [_lock unlock];
    return busy;
}

- (BOOL)acquireLock:(NSString *)identifier error:(NSError **)error
{
    NSParameterAssert(identifier.length > 0);
    [_lock lock];
    if ([_busyIdentifiers containsObject:identifier]) {
        [_lock unlock];
        if (error != nil) {
            *error = DUErrorMake(DUErrorDeviceBusy,
                                 [NSString stringWithFormat:@"%@ is busy",
                                            identifier]);
        }
        return NO;
    }
    [_busyIdentifiers addObject:identifier];
    [_lock unlock];
    return YES;
}

- (void)releaseLock:(NSString *)identifier
{
    if (identifier.length == 0) {
        return;
    }
    [_lock lock];
    [_busyIdentifiers removeObject:identifier];
    [_lock unlock];
}

// --- Observer fan-out ------------------------------------------------------

// Operations post their events on the main thread, so this runs there.
- (void)operationNotification:(NSNotification *)note
{
    DUOperation *operation = note.userInfo[kDUUserInfoOperationKey];
    NSString *operationId = operation.identifier;
    if (operationId.length == 0) {
        return;
    }

    BOOL terminal =
        [note.name isEqualToString:DUOperationDidFinishNotification] ||
        [note.name isEqualToString:DUOperationDidFailNotification];

    [_lock lock];
    NSString *resource = _operationLocks[operationId];
    DUCallbackPair *callbacks = _operationCallbacks[operationId];
    if (terminal) {
        [_operationLocks removeObjectForKey:operationId];
        [_operationCallbacks removeObjectForKey:operationId];
    }
    [_lock unlock];

    if (!terminal && callbacks.progress != nil &&
        [note.name isEqualToString:DUOperationDidUpdateNotification]) {
        callbacks.progress(operation.progress, operation.message);
    }

    if (terminal) {
        [self releaseLock:resource];
        if (callbacks.completion != nil) {
            callbacks.completion(note.userInfo[kDUUserInfoErrorKey]);
        }
    }
}

// --- Convenience starter -----------------------------------------------------

- (DUOperation *)repairObject:(DUStorageObject *)object
                   onProgress:(void (^)(double progress, NSString *message))progress
                 onCompletion:(void (^)(NSError *error))completion
                        error:(NSError **)error
{
    NSParameterAssert(object != nil);

    NSError *localError = nil;
    if (![self acquireLock:object.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DURepairOperation *operation =
        [[DURepairOperation alloc] initWithBackend:_backend object:object];

    [_lock lock];
    _operationLocks[operation.identifier] = object.identifier;
    if (progress != nil || completion != nil) {
        DUCallbackPair *pair = [[DUCallbackPair alloc] init];
        pair.progress = progress;
        pair.completion = completion;
        _operationCallbacks[operation.identifier] = pair;
    }
    [_lock unlock];

    if (![_operationManager startOperation:operation error:&localError]) {
        [_lock lock];
        [_operationLocks removeObjectForKey:operation.identifier];
        [_operationCallbacks removeObjectForKey:operation.identifier];
        [_lock unlock];
        [self releaseLock:object.identifier];
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    return operation;
}

- (DUOperation *)verifyObject:(DUStorageObject *)object
                   onProgress:(void (^)(double progress, NSString *message))progress
                 onCompletion:(void (^)(NSError *error))completion
                        error:(NSError **)error
{
    NSParameterAssert(object != nil);

    NSError *localError = nil;
    if (![self acquireLock:object.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DUVerifyOperation *operation =
        [[DUVerifyOperation alloc] initWithBackend:_backend object:object];

    [_lock lock];
    _operationLocks[operation.identifier] = object.identifier;
    if (progress != nil || completion != nil) {
        DUCallbackPair *pair = [[DUCallbackPair alloc] init];
        pair.progress = progress;
        pair.completion = completion;
        _operationCallbacks[operation.identifier] = pair;
    }
    [_lock unlock];

    if (![_operationManager startOperation:operation error:&localError]) {
        // Rejected before it ran; drop bookkeeping and free the device so a
        // failed start can never leave a phantom busy state behind.
        [_lock lock];
        [_operationLocks removeObjectForKey:operation.identifier];
        [_operationCallbacks removeObjectForKey:operation.identifier];
        [_lock unlock];
        [self releaseLock:object.identifier];
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    return operation;
}

- (DUOperation *)createImageFromObject:(DUStorageObject *)object
                               options:(NSDictionary *)options
                            onProgress:(void (^)(double progress, NSString *message))progress
                          onCompletion:(void (^)(NSError *error))completion
                                 error:(NSError **)error
{
    NSParameterAssert(object != nil);

    if (![_backend respondsToSelector:@selector(createImageFromObject:options:progress:completion:)]) {
        if (error != nil) {
            *error = DUErrorMake(DUErrorUnsupportedOperation,
                                 NSLocalizedString(
                                     @"This backend cannot create images.",
                                     nil));
        }
        return nil;
    }

    NSError *localError = nil;
    if (![self acquireLock:object.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DUCreateImageOperation *operation =
        [[DUCreateImageOperation alloc] initWithBackend:_backend
                                                 object:object
                                                options:options];

    [_lock lock];
    _operationLocks[operation.identifier] = object.identifier;
    if (progress != nil || completion != nil) {
        DUCallbackPair *pair = [[DUCallbackPair alloc] init];
        pair.progress = progress;
        pair.completion = completion;
        _operationCallbacks[operation.identifier] = pair;
    }
    [_lock unlock];

    if (![_operationManager startOperation:operation error:&localError]) {
        [_lock lock];
        [_operationLocks removeObjectForKey:operation.identifier];
        [_operationCallbacks removeObjectForKey:operation.identifier];
        [_lock unlock];
        [self releaseLock:object.identifier];
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    return operation;
}

- (NSArray<NSDictionary *> *)imageCreationFormats
{
    if ([_backend respondsToSelector:@selector(imageCreationFormats)]) {
        return [(id)_backend imageCreationFormats] ?: @[];
    }
    return @[];
}

// --- Backend passthrough --------------------------------------------------

- (NSArray<NSDictionary *> *)supportedFormatsForObject:(DUStorageObject *)object
{
    // Optional protocol method; absence means "no formats offered".
    if ([_backend respondsToSelector:@selector(supportedFormatsForObject:)]) {
        return [(id)_backend supportedFormatsForObject:object] ?: @[];
    }
    return @[];
}

- (NSArray<NSDictionary *> *)eraseSecurityOptions
{
    // The pinned protocol defines no query method, so the standard choices
    // are derived from the shared constants here.
    return @[
        @{ kDUEraseSecurityMethodKey : kDUEraseMethodStandardKey },
        @{ kDUEraseSecurityMethodKey : kDUEraseMethodZerosKey },
    ];
}

@end
