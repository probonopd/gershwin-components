/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWBuildPreflight - scans a source tree for #include/#import directives
 * before a build, resolves missing system headers against the PackageManager
 * header database, and - with explicit user consent - installs the packages
 * that provide them.
 *
 * The scan is deliberately a superset: it walks every source file in the
 * tree, so headers pulled in by conditionally-compiled or vendored code are
 * also covered.  Headers that exist in the project tree itself, GNUstep /
 * AppKit / Foundation headers (not in the database), and headers whose
 * package is already installed are all left alone.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GWPreflightDecision) {
    GWPreflightDecisionProceed = 0,  // nothing missing, installed, or skipped
    GWPreflightDecisionAbort,        // user cancelled or an install failed
};

// Progress forwarding so the caller can update a progress window / build log
// (BuildController) or print to the console (main.m console path).
typedef void (^GWPreflightProgressBlock)(float progress, NSString *message);
typedef void (^GWPreflightOutputBlock)(NSString *line);

@interface GWBuildPreflight : NSObject

- (instancetype)initWithSourceRoot:(NSString *)sourceRoot
                      makefilePath:(NSString *)makefilePath;

// Unsupported-technology names from Build.app's Blacklist.plist; blacklisted
// headers are never resolved to packages.
@property (copy, nullable) NSArray<NSString *> *blacklist;

// When YES, the consent prompt reads from stdin instead of showing an NSAlert
// (used by the no-DISPLAY console path).
@property (getter=isConsoleMode) BOOL consoleMode;

// When YES, skip the consent prompt and install immediately (CI use).
@property BOOL installMissing;

// Icon shown in the GUI consent prompt.  The caller passes the same product
// icon the progress window displays, so both windows agree on what is being
// built.  Falls back to the application icon when unset.
@property (strong, nullable) NSImage *iconImage;

// Runs the whole preflight.  Returns Proceed when nothing is missing or the
// missing packages were installed (or the user chose to skip); Abort when the
// user cancelled or an install failed to make the headers available.
// On Abort caused by a failure, *error is set; on user cancel it is nil.
- (GWPreflightDecision)runWithProgress:(nullable GWPreflightProgressBlock)progress
                                output:(nullable GWPreflightOutputBlock)output
                                 error:(NSError **)error;

// Packages that would be / were installed (valid after run for display).
@property (readonly, copy) NSArray<NSString *> *pendingPackages;

// YES when run actually installed packages (so the caller can re-run the
// configure/prebuild step, which may have missed headers the packages now
// provide).
@property (readonly) BOOL installedPackages;

// Headers that were not found in the database (diagnostics; never fatal).
@property (readonly, copy) NSArray<NSString *> *unresolvedHeaders;

// Blacklisted headers encountered while scanning.  They are never offered for
// installation; the caller shows an "unsupported technology, consider an
// alternative" hint instead.
@property (readonly, copy) NSArray<NSString *> *blockedHeaders;

@end

NS_ASSUME_NONNULL_END