/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Platform-level report of what the backend itself supports, independent of
// any single storage object. The UI enables whole feature areas from these
// flags and diagnostics render them via -reportDictionary
// (ARCHITECTURE.md section 79). All flags default to NO.
//
// The @implementation lives in DUBackendFactory.m: the wave file set pins
// this header without a matching .m, and the factory is the only component
// that needs the synthesized accessors.
@interface DUBackendReport : NSObject

@property (nonatomic) BOOL discovery;
@property (nonatomic) BOOL mountManagement;
@property (nonatomic) BOOL partitioning;
@property (nonatomic) BOOL filesystemFormat;
@property (nonatomic) BOOL filesystemRepair;
@property (nonatomic) BOOL secureErase;
@property (nonatomic) BOOL raidManagement;
@property (nonatomic) BOOL imageCreate;
@property (nonatomic) BOOL imageConvert;
@property (nonatomic) BOOL imageResize;
@property (nonatomic) BOOL burn;

- (void)setAll:(BOOL)value;

// Human-readable diagnostic dictionary mapping section 79 labels to
// @"yes"/@"no" strings, plus a "Platform" entry naming the OS.
- (NSDictionary<NSString *, NSString *> *)reportDictionary;

@end
