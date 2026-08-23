/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Parses the text output of FreeBSD geom(8):
//
//   geom disk list          - one Geom block per disk
//   geom part list <device> - one Geom block with partition providers
//
// Structure of that output: an optional "Geom name: ..." header with plain
// attribute lines ("state: OK", "scheme: GPT", "fwheads: 16", ...), then a
// "providers:" section of numbered blocks:
//
//   providers:
//   1. Name: ada0p1
//      Mediasize: 536870912 (512M)
//      label: efiboot0
//   2. Name: ada0p2
//      ...
//
// followed by a "consumers:" section, which is ignored.
//
// Output: one dictionary per provider, in input order. Attribute keys are
// normalized by stripping surrounding whitespace and inner spaces and
// lowercasing only the first letter, so "Mediasize" -> "mediasize",
// "Geom name" -> "geomname", "fwheads" stays "fwheads". Values are kept as
// raw trimmed STRINGS exactly as printed; callers convert numbers. In
// particular "mediasize" keeps its full form "536870912 (512M)" - take the
// leading integer when bytes are needed.
//
// Attributes of the enclosing Geom header (everything before "providers:")
// are inherited into every provider dictionary of that geom, so "scheme",
// "fwheads", etc. travel with each partition. The provider's own attributes
// win on key collisions.
//
// Commonly consumed keys after normalization: "name" (e.g. "ada0p1"),
// "geomname", "mediasize", "sectorsize", "descr" (disk description),
// "ident", "mode", "fwheads", "fwsectors", "scheme", "label", "type"
// (partition type like "freebsd-ufs"), "index", "start", "end", "len",
// "offset", "rawuuid", "rawtype", "efimedia".
@interface DUFreeBSDGEOMParser : NSObject

// Returns one dictionary per provider block. nil or empty input yields an
// empty array; unrecognized lines are skipped.
+ (NSArray<NSDictionary<NSString *, id> *> *)parseListOutput:(NSString *)output;

@end
