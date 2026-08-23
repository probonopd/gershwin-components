/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "DUStorageObject.h"

// Lifecycle per ARCHITECTURE.md section 30:
// Pending -> Preparing -> Running -> {Completed | Failed | (Cancelling ->) Cancelled}
typedef NS_ENUM(NSInteger, DUOperationState) {
    DUOperationStatePending = 0,
    DUOperationStatePreparing,
    DUOperationStateRunning,
    DUOperationStateCancelling,
    DUOperationStateCancelled,
    DUOperationStateCompleted,
    DUOperationStateFailed,
};

extern NSString *const DUOperationStateNamePending;
extern NSString *const DUOperationStateNamePreparing;
extern NSString *const DUOperationStateNameRunning;
extern NSString *const DUOperationStateNameCancelling;
extern NSString *const DUOperationStateNameCancelled;
extern NSString *const DUOperationStateNameCompleted;
extern NSString *const DUOperationStateNameFailed;

// Base class for all long-running storage work. -start spawns a worker
// NSThread that invokes the subclass -execute override; progress, state and
// completion are lock-protected so they may be touched from any thread.
//
// Notification contract: DidStart/DidUpdate/DidFinish/DidFail are delivered
// on the MAIN thread (ARCHITECTURE.md sections 31/53), so observers need no
// locking of their own. UserInfo carries kDUUserInfoOperationKey = self,
// kDUUserInfoObjectKey = primaryObject when present and kDUUserInfoErrorKey
// on failure. The object: of every posted NSNotification is the operation.
@interface DUOperation : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, readonly) DUOperationState state;
@property (nonatomic, readonly) double progress;          // 0..1
@property (nonatomic, copy, readonly) NSString *message;
@property (nonatomic, strong, readonly) NSDate *startTime;   // nil until started
@property (nonatomic, strong, readonly) NSDate *finishTime;  // nil until finished
@property (nonatomic, strong, readonly) NSError *error;      // nil unless failed

// Main storage object this operation targets; nil for objectless work such
// as plain image conversion. Used for conflict detection by the managers.
@property (nonatomic, strong, readonly) DUStorageObject *primaryObject;

// Designated initializer. object may be nil for objectless work.
- (instancetype)initWithPrimaryObject:(DUStorageObject *)object
    NS_DESIGNATED_INITIALIZER;

// Human-readable summary for UI lists and history.
- (NSString *)displayName;

// Runs -execute on a fresh worker thread. Valid only from Pending; later
// calls are ignored so double-start stays harmless.
- (void)start;

// Cooperative cancellation. Sets the flag subclasses poll between steps and
// moves a running operation to Cancelling; the operation itself performs the
// final transition once its in-flight step notices. A Pending operation is
// finalized as Cancelled immediately.
- (void)cancel;

// --- Subclass SPI -------------------------------------------------------

// Override point; called exactly once on a worker thread. Implementations
// must end by calling one of the finish methods below from any thread.
- (void)execute;

// Atomic cancel flag for polling at step boundaries.
@property (nonatomic, readonly) BOOL cancelRequested;

// Thread-safe progress publication; also posts DidUpdate on the main thread.
- (void)setProgress:(double)progress message:(NSString *)message;

// Terminal transitions; only the first call wins, later ones are ignored.
// A nil error completes the operation; an error whose code is
// DUErrorCancelled (or a success arriving after -cancel) marks it Cancelled,
// everything else Failed. Returns NO if already terminal.
- (BOOL)finishWithError:(NSError *)error;

@end
