/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWSudoHelper - Resolve the privilege-escalation command at runtime.
 *
 * The package backends must run the system package manager as root.  sudo's
 * location differs per platform: /usr/bin on Linux, but /usr/local/bin on the
 * BSDs (FreeBSD, OpenBSD, NextBSD).  Hardcoding /usr/bin/sudo broke every
 * backend on *BSD ("task has invalid launch path").  This helper also skips
 * sudo entirely when the process is already root.
 */

#import <Foundation/Foundation.h>

// Path to the sudo binary.  We never hardcode its install location; NSTask
// resolves a launch path without a slash via $PATH, so sudo is found wherever
// it lives (Linux: /usr/bin, BSDs: /usr/local/bin).  Returns a bare "sudo".
NSString *GWSudoPath(void);

// argv flags to pass to sudo, or an empty array when already root (run the
// package manager directly).  When non-empty, the command must be launched via
// GWSudoPath() with these flags followed by the package-manager command.
// Returns @[ @"-A", @"-E" ] when escalation is needed, else @[].
NSArray<NSString *> *GWSudoArgPrefix(void);
