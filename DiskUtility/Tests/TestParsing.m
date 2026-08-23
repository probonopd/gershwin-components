/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// ObjectTesting coverage for the Wave-1 parsers and DUParsing helpers.
// Every parser is fed the recorded fixture from Tests/Fixtures and the
// assertions check the documented output contract (see the headers in
// Sources/Backend/Parsers).

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "DUParsing.h"
#import "DULsblkParser.h"
#import "DUBlkidParser.h"
#import "DUFreeBSDGEOMParser.h"
#import "DUOpenBSDDisklabelParser.h"
#import "DUNetBKSDisklabelParser.h"

#import "TestFixtures.h"

// PRODUCT GAP (reported): the k* key constants are part of the parsers'
// documented output contract, but DULsblkParser.h / DUBlkidParser.h describe
// them in comments only and do not declare them. Until the headers export
// them, redeclare here so the tests link the very symbols production code
// uses instead of hard-coding the string values a second time.
extern NSString * const kLsblkKeyName;
extern NSString * const kLsblkKeyParentName;
extern NSString * const kLsblkKeyPath;
extern NSString * const kLsblkKeyType;
extern NSString * const kLsblkKeySizeBytes;
extern NSString * const kLsblkKeyFstype;
extern NSString * const kLsblkKeyMountPoint;
extern NSString * const kLsblkKeyLabel;
extern NSString * const kLsblkKeyPartUUID;
extern NSString * const kLsblkKeyUUID;
extern NSString * const kLsblkKeyModel;
extern NSString * const kLsblkKeyReadOnly;
extern NSString * const kLsblkKeyRemovable;
extern NSString * const kLsblkKeyHotplug;
extern NSString * const kLsblkKeyMajorMinor;

extern NSString * const kBkidKeyDevice;
extern NSString * const kBkidKeyUuid;
extern NSString * const kBkidKeyType;
extern NSString * const kBkidKeyLabel;
extern NSString * const kBkidKeyPartUuid;
extern NSString * const kBkidKeyPartLabel;
extern NSString * const kBkidKeyPartEntryNumber;

static const unsigned long long MiB = 1024ull * 1024ull;
static const unsigned long long GiB = 1024ull * 1024ull * 1024ull;
static const unsigned long long TiB = 1024ull * 1024ull * 1024ull * 1024ull;

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    // ------------------------------------------------------------------
    // DULsblkParser on lsblk-pairs.txt
    // ------------------------------------------------------------------
    {
        NSString *output = TestFixtureNamed(@"Linux/lsblk-pairs.txt");
        NSArray *devices = [DULsblkParser parsePairsOutput:output];

        PASS(devices.count == 7,
             "lsblk fixture has 7 devices (got %lu)",
             (unsigned long)devices.count);

        BOOL orderOK = devices.count == 7
            && [[devices[0] objectForKey:kLsblkKeyName] isEqual:@"sda"]
            && [[devices[3] objectForKey:kLsblkKeyName] isEqual:@"sda3"]
            && [[devices[6] objectForKey:kLsblkKeyName] isEqual:@"sr0"];
        PASS(orderOK, "lsblk result keeps input device order");

        NSDictionary *sda = devices[0];
        NSNumber *sdaSize = [sda objectForKey:kLsblkKeySizeBytes];
        PASS(sdaSize.unsignedLongLongValue == 160041885696,
             "sda size is exactly 160041885696 bytes");
        PASS([[sda objectForKey:kLsblkKeyType] isEqual:@"disk"],
             "sda type is disk");
        PASS([[sda objectForKey:kLsblkKeyModel]
                 isEqual:@"Samsung SSD 850 EVO"],
             "sda model string with spaces survives pair parsing");
        PASS([[sda objectForKey:kLsblkKeyMajorMinor] isEqual:@"8:0"],
             "sda MAJ:MIN kept as raw major:minor string");
        PASS([sda objectForKey:kLsblkKeyParentName] == nil,
             "whole disks have no PKNAME entry");
        PASS([sda objectForKey:kLsblkKeyFstype] == nil,
             "empty FSTYPE column is dropped, key absent");
        PASS([sda objectForKey:kLsblkKeyMountPoint] == nil,
             "empty MOUNTPOINT column is dropped, key absent");

        NSDictionary *sda1 = devices[1];
        PASS([[sda1 objectForKey:kLsblkKeyFstype] isEqual:@"vfat"],
             "sda1 fstype is vfat");
        PASS([[sda1 objectForKey:kLsblkKeyMountPoint] isEqual:@"/boot/efi"],
             "sda1 mountpoint is /boot/efi");
        PASS([[sda1 objectForKey:kLsblkKeyParentName] isEqual:@"sda"],
             "sda1 parent name comes from PKNAME");
        PASS([[sda1 objectForKey:kLsblkKeyLabel] isEqual:@"ESP"],
             "sda1 label is ESP");

        NSDictionary *sda3 = devices[3];
        PASS([[sda3 objectForKey:kLsblkKeyMountPoint] isEqual:@"[SWAP]"],
             "lsblk [SWAP] marker kept literally as mountpoint");

        NSDictionary *sdb1 = devices[5];
        PASS([[sdb1 objectForKey:kLsblkKeyMountPoint]
                 isEqual:@"/media/usb stick"],
             "\\x20 escapes decode to plain bytes (usb stick mountpoint)");

        NSDictionary *sr0 = devices[6];
        PASS([[sr0 objectForKey:kLsblkKeyType] isEqual:@"rom"],
             "sr0 type is rom");
        PASS([[sr0 objectForKey:kLsblkKeyReadOnly] boolValue] == YES,
             "sr0 RO=1 becomes readOnly YES");
        PASS([[sr0 objectForKey:kLsblkKeyRemovable] boolValue] == YES,
             "sr0 RM=1 becomes removable YES");
        NSNumber *sr0Size = [sr0 objectForKey:kLsblkKeySizeBytes];
        PASS(sr0Size.unsignedLongLongValue == 1073741312,
             "sr0 size parsed from SIZE column");

        NSArray *emptyNil = [DULsblkParser parsePairsOutput:nil];
        PASS(emptyNil != nil && emptyNil.count == 0,
             "nil lsblk input yields empty array");
    }

    // ------------------------------------------------------------------
    // DUBlkidParser on blkid.txt
    // ------------------------------------------------------------------
    {
        NSString *output = TestFixtureNamed(@"Linux/blkid.txt");
        NSArray *devices = [DUBlkidParser parseFullOutput:output];

        PASS(devices.count == 5,
             "blkid fixture has 5 devices (got %lu)",
             (unsigned long)devices.count);

        NSDictionary *sda1 = devices[0];
        PASS([[sda1 objectForKey:kBkidKeyDevice] isEqual:@"/dev/sda1"],
             "device path taken from text before colon");
        PASS([[sda1 objectForKey:kBkidKeyType] isEqual:@"vfat"],
             "sda1 TYPE=vfat");
        PASS([[sda1 objectForKey:kBkidKeyLabel] isEqual:@"ESP"],
             "sda1 LABEL=ESP");
        PASS([[sda1 objectForKey:kBkidKeyPartLabel]
                 isEqual:@"EFI System Partition"],
             "PARTLABEL value with spaces preserved");
        PASS([[sda1 objectForKey:kBkidKeyPartEntryNumber] isEqual:@"1"],
             "PART_ENTRY_NUMBER kept as raw string \"1\"");
        PASS([[sda1 objectForKey:kBkidKeyPartUuid]
                 isEqual:@"d6c0cb26-0b2f-11e4-9d81-0025905151bc"],
             "PARTUUID captured");

        NSDictionary *sdb1 = devices[3];
        PASS([[sdb1 objectForKey:@"secType"] isEqual:@"msdos"],
             "unknown SEC_TYPE token normalized to secType passthrough");
        PASS([[sdb1 objectForKey:kBkidKeyUuid] isEqual:@"ABCD-EF12"],
             "sdb1 filesystem UUID");

        NSDictionary *sr0 = devices[4];
        PASS([[sr0 objectForKey:kBkidKeyType] isEqual:@"iso9660"],
             "sr0 filesystem iso9660");
        PASS([[sr0 objectForKey:kBkidKeyLabel] isEqual:@"GERSHWIN_LIVE"],
             "sr0 label GERSHWIN_LIVE");
    }

    // ------------------------------------------------------------------
    // DUFreeBSDGEOMParser on geom-part-list-ada0.txt
    // ------------------------------------------------------------------
    {
        NSString *output =
            TestFixtureNamed(@"FreeBSD/geom-part-list-ada0.txt");
        NSArray *providers = [DUFreeBSDGEOMParser parseListOutput:output];

        PASS(providers.count == 3,
             "geom part list yields 3 providers, consumers ignored "
             "(got %lu)",
             (unsigned long)providers.count);

        NSDictionary *p1 = providers[0];
        PASS([[p1 objectForKey:@"name"] isEqual:@"ada0p1"],
             "first provider is ada0p1");
        PASS([[p1 objectForKey:@"scheme"] isEqual:@"GPT"],
             "scheme GPT inherited from geom header into provider");
        PASS([[p1 objectForKey:@"geomname"] isEqual:@"ada0"],
             "Geom name normalized to geomname key");
        NSString *media1 = [p1 objectForKey:@"mediasize"];
        PASS([media1 hasPrefix:@"536870912"],
             "mediasize keeps full \"bytes (human)\" form");
        PASS([[p1 objectForKey:@"label"] isEqual:@"efiboot0"],
             "provider label attribute captured");

        NSDictionary *p2 = providers[1];
        PASS([[p2 objectForKey:@"name"] isEqual:@"ada0p2"],
             "second provider is ada0p2");
        unsigned long long media2 = [DUParsing
            unsignedLongLongFromString:[p2 objectForKey:@"mediasize"]];
        PASS(media2 == 150319855360,
             "ada0p2 mediasize leading integer is 150319855360 bytes");
        PASS([[p2 objectForKey:@"type"] isEqual:@"freebsd-ufs"],
             "ada0p2 partition type freebsd-ufs");

        NSDictionary *p3 = providers[2];
        PASS([[p3 objectForKey:@"name"] isEqual:@"ada0p3"],
             "third provider is ada0p3");
        PASS([[p3 objectForKey:@"type"] isEqual:@"freebsd-swap"],
             "ada0p3 partition type freebsd-swap");
        PASS([[p3 objectForKey:@"index"] isEqual:@"3"],
             "provider index attribute kept as raw string");
    }

    // ------------------------------------------------------------------
    // DUOpenBSDDisklabelParser on disklabel-sd0.txt
    // ------------------------------------------------------------------
    {
        NSString *output = TestFixtureNamed(@"OpenBSD/disklabel-sd0.txt");
        NSDictionary *result =
            [DUOpenBSDDisklabelParser parseDisklabelOutput:output];

        PASS(result != nil, "OpenBSD disklabel fixture parses");

        NSNumber *total = [result objectForKey:kDisklabelKeyTotalSectors];
        PASS(total.unsignedLongLongValue == 78165360,
             "total sectors is 78165360");
        NSNumber *sectorSize = [result objectForKey:kDisklabelKeySectorSize];
        PASS(sectorSize.unsignedLongLongValue == 512,
             "bytes/sector reported as 512");

        NSArray *parts = [result objectForKey:kDisklabelKeyPartitions];
        PASS(parts.count == 5,
             "5 partition rows parsed a b c d i (got %lu)",
             (unsigned long)parts.count);

        NSMutableArray *letters = [NSMutableArray array];
        for (NSDictionary *part in parts) {
            [letters addObject:[part objectForKey:kDisklabelKeyLetter]];
        }
        NSArray *wantLetters =
            @[ @"a", @"b", @"c", @"d", @"i" ];
        PASS([letters isEqualToArray:wantLetters],
             "partition letters are a b c d i in label order");

        NSDictionary *a = parts[0];
        NSNumber *aSize = [a objectForKey:kDisklabelKeySizeBytes];
        PASS(aSize.unsignedLongLongValue == 2104515ull * 512ull,
             "'a' size converted from sectors to bytes");
        NSNumber *aOffset = [a objectForKey:kDisklabelKeyOffsetBytes];
        PASS(aOffset.unsignedLongLongValue == 64ull * 512ull,
             "'a' offset starts at sector 64");
        PASS([[a objectForKey:kDisklabelKeyFstype] isEqual:@"4.2BSD"],
             "'a' fstype token untranslated");
        PASS([[a objectForKey:kDisklabelKeyMountPoint] isEqual:@"/"],
             "'a' mount point from trailing # comment");

        NSDictionary *c = parts[2];
        NSNumber *cSize = [c objectForKey:kDisklabelKeySizeBytes];
        PASS(cSize.unsignedLongLongValue == 78165360ull * 512ull,
             "'c' spans the whole unit");
        PASS([c objectForKey:kDisklabelKeyMountPoint] == nil,
             "'c' row has no comment so no mount point key");

        NSDictionary *i = parts[4];
        PASS([[i objectForKey:kDisklabelKeyFstype] isEqual:@"NTFS"],
             "'i' fstype NTFS");
        PASS([i objectForKey:kDisklabelKeyMountPoint] == nil,
             "'i' has no mount point comment");
    }

    // ------------------------------------------------------------------
    // DUNetBKSDisklabelParser delegates to the shared engine
    // ------------------------------------------------------------------
    {
        NSString *output = TestFixtureNamed(@"NetBSD/disklabel-wd0.txt");
        NSDictionary *netResult =
            [DUNetBKSDisklabelParser parseDisklabelOutput:output];
        NSDictionary *openResult =
            [DUOpenBSDDisklabelParser parseDisklabelOutput:output];

        PASS(netResult != nil, "NetBSD disklabel fixture parses");

        // Same grammar engine means byte-identical dictionaries; that is
        // the whole point of the delegation documented in the header.
        PASS_EQUAL(netResult, openResult,
                   "NetBSD parser output identical to OpenBSD engine");

        NSNumber *total =
            [netResult objectForKey:kDisklabelKeyTotalSectors];
        PASS(total.unsignedLongLongValue == 156301488,
             "wd0 total sectors is 156301488");

        NSArray *parts = [netResult objectForKey:kDisklabelKeyPartitions];
        NSMutableArray *letters = [NSMutableArray array];
        for (NSDictionary *part in parts) {
            [letters addObject:[part objectForKey:kDisklabelKeyLetter]];
        }
        NSArray *wantLetters = @[ @"a", @"b", @"c", @"d", @"e", @"g" ];
        PASS([letters isEqualToArray:wantLetters],
             "wd0 letters are a b c d e g");

        NSDictionary *g = parts[5];
        PASS([[g objectForKey:kDisklabelKeyFstype] isEqual:@"MSDOS"],
             "'g' fstype MSDOS");
        NSNumber *gSize = [g objectForKey:kDisklabelKeySizeBytes];
        PASS(gSize.unsignedLongLongValue == 37748736ull * 512ull,
             "'g' size converted with reported sector size");

        NSDictionary *e = parts[4];
        PASS([[e objectForKey:kDisklabelKeyMountPoint] isEqual:@"/usr"],
             "'e' mounts /usr via cpg/sgs bracket group handling");
    }

    // ------------------------------------------------------------------
    // DUParsing helpers
    // ------------------------------------------------------------------
    {
        // parseSizeString
        NSNumber *fiveHundredG = [DUParsing parseSizeString:@"500G"];
        PASS(fiveHundredG.unsignedLongLongValue == 500ull * GiB,
             "500G parses to 500 GiB in bytes");
        NSNumber *eightM = [DUParsing parseSizeString:@"8M"];
        PASS(eightM.unsignedLongLongValue == 8ull * MiB,
             "8M parses to 8 MiB in bytes");
        NSNumber *plain = [DUParsing parseSizeString:@"1024"];
        PASS(plain.unsignedLongLongValue == 1024,
             "bare number is already bytes");
        NSNumber *onePointFiveT = [DUParsing parseSizeString:@"1.5T"];
        PASS(onePointFiveT.unsignedLongLongValue ==
                 (unsigned long long)(1.5 * (double)TiB),
             "1.5T parses to fractional terabytes rounded up");
        PASS([DUParsing parseSizeString:nil] == nil,
             "nil token yields nil");
        PASS([DUParsing parseSizeString:@""] == nil,
             "empty token yields nil");
        PASS([DUParsing parseSizeString:@"-"] == nil,
             "\"-\" placeholder yields nil");
        PASS([DUParsing parseSizeString:@"abc"] == nil,
             "non-numeric token yields nil");

        // humanReadableSizeFromBytes
        NSString *human = [DUParsing humanReadableSizeFromBytes:160041885696];
        // Testing.h formats through printf(), so no %@ conversion here.
        PASS([human hasPrefix:@"149."],
             "160041885696 renders as 149.x (got %s)",
             human.UTF8String);

        NSString *tiny = [DUParsing humanReadableSizeFromBytes:7];
        PASS([tiny isEqualToString:@"7 B"], "byte-range renders without decimals");

        // boolFromToken
        PASS([DUParsing boolFromToken:@"1"] == YES, "token 1 is true");
        PASS([DUParsing boolFromToken:@"yes"] == YES, "token yes is true");
        PASS([DUParsing boolFromToken:@"YES"] == YES,
             "case-insensitive yes is true");
        PASS([DUParsing boolFromToken:@"true"] == YES, "token true is true");
        PASS([DUParsing boolFromToken:@"on"] == YES, "token on is true");
        PASS([DUParsing boolFromToken:@" y "] == YES,
             "surrounding whitespace tolerated");
        PASS([DUParsing boolFromToken:@"0"] == NO, "token 0 is false");
        PASS([DUParsing boolFromToken:@"no"] == NO, "token no is false");
        PASS([DUParsing boolFromToken:@"false"] == NO,
             "token false is false");
        PASS([DUParsing boolFromToken:@"off"] == NO, "token off is false");
        PASS([DUParsing boolFromToken:@""] == NO, "empty token is false");
        PASS([DUParsing boolFromToken:nil] == NO, "nil token is false");
        PASS([DUParsing boolFromToken:@"random"] == NO,
             "unrecognized token defaults to false");

        // unsignedLongLongFromString
        PASS([DUParsing unsignedLongLongFromString:@"78165360"] ==
                 78165360ull,
             "plain decimal digits parse exactly");
        PASS([DUParsing unsignedLongLongFromString:@"150319855360 (140G)"] ==
                 150319855360ull,
             "leading integer extracted from geom mediasize form");
        PASS([DUParsing unsignedLongLongFromString:@"42abc"] == 42ull,
             "trailing garbage after digits is ignored");
        PASS([DUParsing unsignedLongLongFromString:@"abc"] == 0ull,
             "garbage-only input yields 0");
        PASS([DUParsing unsignedLongLongFromString:@""] == 0ull,
             "empty input yields 0");
        PASS([DUParsing unsignedLongLongFromString:nil] == 0ull,
             "nil input yields 0");

        // trimmedString
        PASS([[DUParsing trimmedString:@"  x  "] isEqualToString:@"x"],
             "surrounding whitespace trimmed");
        PASS([[DUParsing trimmedString:nil] isEqualToString:@""],
             "nil trims to empty string");
    }

    [pool release];
    return 0;
}
