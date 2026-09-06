/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import <Foundation/Foundation.h>

// Disk image adapter (ARCHITECTURE.md section 88): raw image creation is
// always available (plain file truncation); conversion, resizing and
// format probing need qemu-img and degrade to UnsupportedOperation /
// capability NO when it is absent.
//
// Threading: every method BLOCKS; callers run them on background threads
// (ARCHITECTURE.md 53).
@interface DULinuxImageTool : NSObject

// YES when qemu-img was found in the fixed tool directories.
+ (BOOL)conversionAvailable;

// Best-effort format identifier for an image file: qemu-img probing when
// available, in-process libarchive content identification next, and a
// file-extension mapping as the final fallback. Returns nil for unknown
// shapes; callers render that as "raw" only where a raw file is certain.
+ (NSString *)probeFormatForImageAtPath:(NSString *)path;

// qemu-img info --output=json reduced to its top-level scalar fields
// (format, virtual-size, actual-size, encrypted, compressed, ...). Returns
// nil and fills *error when qemu-img is missing or the output cannot be
// parsed. Never shells out; the path travels as an argument.
+ (NSDictionary<NSString *, id> *)infoForImageAtPath:(NSString *)path
                                               error:(NSError **)error;

// Creates an empty raw image of the given size (sparse truncate). Refuses
// to overwrite an existing file so destructive decisions stay with the UI
// layer, which confirms them explicitly.
+ (NSError *)createImageFileAtPath:(NSString *)path
                          sizeBytes:(unsigned long long)sizeBytes;

// Converts between image formats (qemu-img convert). The destination must
// not exist yet; qemu-img refuses to clobber silently and so do we.
+ (NSError *)convertImageAtPath:(NSString *)sourcePath
                       toPath:(NSString *)destinationPath
                     format:(NSString *)format;

// Grows or shrinks an image by deltaBytes (qemu-img resize path +/-N).
+ (NSError *)resizeImageAtPath:(NSString *)path
                 sizeDeltaBytes:(long long)deltaBytes;

// Streams a block device (whole disk or single partition) to an image file.
// format "raw" copies bytes directly; "gz" pipes the same stream through
// gzip(1) via a pipe we own (no shell). progress reports bytes-copied
// fraction of sourceBytes; cancelCheck is polled between chunks and should
// return YES when the user asked to abort. Refuses to overwrite files.
+ (NSError *)streamDeviceAtPath:(NSString *)devicePath
                       sizeBytes:(unsigned long long)sourceBytes
                        toImage:(NSString *)path
                         format:(NSString *)format
                       progress:(void (^)(double fraction,
                                          NSString *message))progress
                     cancelCheck:(BOOL (^)(void))cancelCheck;

// Image-creation targets offered by this tool: raw and gz always, plus the
// qemu-img conversion formats when it is installed.
+ (NSArray<NSDictionary *> *)imageCreationFormats;



#endif /* defined(__linux__) */

// ---- Verification helpers ------------------------------------------------

// SHA-256 hex digest over the first sizeBytes of `path`. Regular files are
// read directly; root-only nodes fall back to a privileged `cat` pipeline
// (sudo -A askpass), mirroring how image creation reads devices. progress
// reports 0..1 over exactly sizeBytes. Returns nil and sets *error when
// the read fails or comes up short.
+ (NSString *)sha256HexForPath:(NSString *)path
                     sizeBytes:(unsigned long long)sizeBytes
                      progress:(void (^)(double fraction))progress
                         error:(NSError **)error;

// SHA-256 hex digest of a gzip file's DECOMPRESSED content, streamed
// through gzip(1) so the digest covers payload bytes, not the container.
// A corrupt archive surfaces as an error even if bytes were emitted.
+ (NSString *)sha256HexOfGzipFile:(NSString *)path
                        sizeBytes:(unsigned long long)uncompressedBytes
                         progress:(void (^)(double fraction))progress
                            error:(NSError **)error;

@end
