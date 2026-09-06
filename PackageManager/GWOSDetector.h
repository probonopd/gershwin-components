/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWOSDetector - OS identification utility.
 * Identifies the current operating system by reading /etc/os-release
 * with fallback to uname for BSD systems. Supports testing via
 * path override for the os-release file.
 */

#import <Foundation/Foundation.h>

@interface GWOSDetector : NSObject

// Returns the primary OS identifier, e.g. "debian", "arch", "freebsd", "openbsd"
+ (NSString *)currentOSIdentifier;

// Returns the ordered search list: primary ID followed by ID_LIKE entries
// e.g. @[@"debian", @"ubuntu"] for Ubuntu when ID=ubuntu ID_LIKE=debian
+ (NSArray<NSString *> *)osSearchOrder;

// Returns the package-manager family of the current OS:
//   "debian" (debian/ubuntu/devuan/kali/linuxmint/raspbian/pop/elementary/zorin)
//   "arch"   (arch/manjaro/endeavouros/arcolinux)
//   "freebsd"(freebsd/ghostbsd/dragonfly)
//   "openbsd"
//   nil      for anything else
// Used both by the backend factory and by the header database to map the
// current OS onto a repository distro.  Returns nil instead of a guess when
// the OS is unknown, so callers can decide to do nothing rather than install
// a wrong package.
+ (nullable NSString *)packageManagerFamily;

// Returns the machine architecture normalized to an AppImage target tuple:
//   "x86_64"  (uname -m x86_64 / amd64)
//   "aarch64" (uname -m aarch64 / arm64)
//   or the raw uname -m string if neither matches.
+ (NSString *)currentArchitecture;

// Testing support: override the path used for os-release detection
// Pass nil to reset to default (/etc/os-release)
+ (void)setOSReleasePathOverride:(nullable NSString *)path;

// Testing support: override uname result (nil resets to real uname)
+ (void)setUnameOverride:(nullable NSString *)unameString;

@end
