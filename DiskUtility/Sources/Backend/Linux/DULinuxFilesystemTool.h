/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import <Foundation/Foundation.h>

// Raw tool output attached to errors alongside the generic localized
// description, so the operation log can show diagnostics without leaking
// them into the primary user-facing message (ARCHITECTURE.md section 46).
extern NSString * const kDUBackendDetailKey;

// Filesystem maintenance adapter (ARCHITECTURE.md section 88): wraps
// fsck.<fstype>, mkfs.<fstype>, wipefs and tune2fs behind intent-level
// calls. Executables are located via DUProcessRunner at call time; a
// missing tool turns into an UnsupportedOperation error or an honest
// capability answer, never into a crash.
//
// Threading: every method BLOCKS until the external tool exits. Callers
// must invoke these from background threads only (ARCHITECTURE.md 53);
// none of them spawn their own workers.
@interface DULinuxFilesystemTool : NSObject

// Filesystem identifiers this adapter knows how to create, in stable
// presentation order. Actual availability still depends on which mkfs
// binaries are installed; use +formatArgumentsForFilesystemType:label:
// to probe.
+ (NSArray<NSString *> *)formattableFilesystemTypes;

// Argument prefix for creating the named filesystem: the executable name
// plus any mandatory flags before the device path, e.g.
// @[ @"mkfs.ext4", @"-F" ]. Returns nil when the identifier is unknown;
// returns non-nil even when the binary is missing so callers can decide
// how to report absence. The label pair (-L/-n/--label) is appended here
// when label is non-empty.
+ (NSArray<NSString *> *)formatArgumentsForFilesystemType:(NSString *)fstype
                                                    label:(NSString *)label;

// fsck executable name for a filesystem identifier ("ext4" -> "fsck.ext4"),
// or nil when no checker exists for that filesystem.
+ (NSString *)checkToolNameForFilesystemType:(NSString *)fstype;

// Resize helper name per filesystem ("resize2fs", "xfs_growfs", ...) or
// nil when that filesystem cannot be grown/shrunk with local tools.
+ (NSString *)resizeToolNameForFilesystemType:(NSString *)fstype;

// ext2/3/4 journal toggling via tune2fs; NO when tune2fs is absent.
+ (BOOL)journalingToggleAvailable;

// Read-only check (fsck.<fstype> -n). Returns nil when the filesystem came
// back clean; otherwise a VerificationFailed/FilesystemError error whose
// userInfo carries raw output under kDUBackendDetailKey. Tool output lines
// stream to progress as (stage fraction, raw line); the fraction walks
// through the fsck pass stages, so callers can show a moving bar.
+ (NSError *)verifyVolumeAtDevicePath:(NSString *)devicePath
                       filesystemType:(NSString *)fstype
                             progress:(void (^)(double progress,
                                                NSString *line))progress;

// Interactive-free repair (fsck.<fstype> -y). Refusing mounted volumes is
// the caller's job (it owns the model state); this layer just runs. Output
// streams exactly like verify.
+ (NSError *)repairVolumeAtDevicePath:(NSString *)devicePath
                       filesystemType:(NSString *)fstype
                             progress:(void (^)(double progress,
                                                NSString *line))progress;

// Removes stale partition/filesystem signatures (wipefs -a) so a fresh
// format cannot inherit leftovers. Fails hard when wipefs exists but fails;
// returns nil immediately when wipefs is not installed (the subsequent
// mkfs overwrites the primary signatures anyway).
+ (NSError *)wipeSignaturesAtDevicePath:(NSString *)devicePath;

// One-pass zero overwrite (dd if=/dev/zero bs=1M status=progress, run
// elevated). Progress is determinate: dd's byte counts map to fractions of
// sizeBytes and its output lines stream through as messages.
+ (NSError *)zeroFillDevicePath:(NSString *)devicePath
                      sizeBytes:(unsigned long long)sizeBytes
                       progress:(void (^)(double progress,
                                          NSString *message))progress;

// Creates the filesystem (mkfs family / mkswap) elevated. mkfs stage lines
// ("Writing inode tables: n/m", superblocks, journal) stream to progress
// with mapped fractions. Returns nil on success.
+ (NSError *)formatVolumeAtDevicePath:(NSString *)devicePath
                       filesystemType:(NSString *)fstype
                                label:(NSString *)label
                             progress:(void (^)(double progress,
                                                NSString *line))progress;

// Adds or removes the ext-family journal (tune2fs -O has_journal /
// ^has_journal). UnsupportedOperation when the filesystem is not ext2-4.
+ (NSError *)toggleJournalingOnDevicePath:(NSString *)devicePath
                       filesystemType:(NSString *)fstype
                                 enable:(BOOL)enable;

@end

#endif /* defined(__linux__) */
