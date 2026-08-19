/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWHeaderDatabase - SQLite-backed lookup of which distro package provides
 * a given C/C++ header.
 *
 * The database schema (see Build/tools/build-headerdb.py):
 *
 *   distro(id, name, include_prefix)      include_prefix is "usr/include/"
 *                                         (Debian, Arch) or "usr/local/include/"
 *                                         (FreeBSD)
 *   header(id, include_name, basename)    include_name is the #include form,
 *                                         e.g. "gphoto2/gphoto2.h"
 *   package(id, distro_id, name)
 *   provider(header_id, package_id)
 *
 * An installed path is always include_prefix || include_name, so a header is
 * "installed" when that file exists on disk; no per-provider path is stored.
 */

#import "GWHeaderDatabase.h"
#import "GWOSDetector.h"
#import "GWPackageManager.h"

#import <sqlite3.h>

@implementation GWHeaderDatabase
{
  sqlite3 *_db;
  NSString *_databasePath;
  NSMutableDictionary *_installedBasenames;
}

#pragma mark - Singleton

+ (instancetype)sharedDatabase
{
  static GWHeaderDatabase *sharedDatabase = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSString *path = [[NSBundle bundleForClass:[GWHeaderDatabase class]] resourcePath];
    path = [path stringByAppendingPathComponent:@"headers.db"];
    sharedDatabase = [[GWHeaderDatabase alloc] initWithPath:path error:NULL];
  });
  return sharedDatabase;
}

#pragma mark - Initialization

- (nullable instancetype)initWithPath:(NSString *)dbPath error:(NSError **)error
{
  self = [super init];
  if (!self) return nil;

  _databasePath = [dbPath copy];

  if (![[NSFileManager defaultManager] fileExistsAtPath:_databasePath])
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorDatabaseUnavailable
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:
                                      @"The header database is missing at %@", _databasePath],
                                }];
      NSLog(@"GWHeaderDatabase [FAIL] init: database missing at %@", _databasePath);
      return nil;
    }

  int rc = sqlite3_open([_databasePath UTF8String], &_db);
  if (rc != SQLITE_OK)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorDatabaseUnavailable
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:
                                      @"Could not open the header database at %@", _databasePath],
                                }];
      NSLog(@"GWHeaderDatabase [FAIL] init: sqlite3_open failed (%d)", rc);
      sqlite3_close(_db);
      _db = NULL;
      return nil;
    }

  // Fast lookups for the read-mostly workload.
  sqlite3_busy_timeout(_db, 3000);
  sqlite3_exec(_db, "PRAGMA query_only = ON;", NULL, NULL, NULL);

  NSLog(@"GWHeaderDatabase [OK] opened %@", _databasePath);
  return self;
}

- (void)dealloc
{
  if (_db)
    sqlite3_close(_db);
  _db = NULL;
}

- (BOOL)isOpen
{
  return _db != NULL;
}

#pragma mark - Distro Mapping

- (nullable NSString *)databaseDistroForCurrentOS
{
  NSString *family = [GWOSDetector packageManagerFamily];
  if ([family isEqualToString:@"debian"])
    return @"debian";
  if ([family isEqualToString:@"arch"])
    return @"arch";
  if ([family isEqualToString:@"freebsd"])
    return @"freebsd";
  // openbsd (and anything unknown) has no data in the database.
  NSLog(@"GWHeaderDatabase <- databaseDistroForCurrentOS: no data for family '%@'", family);
  return nil;
}

#pragma mark - Queries

- (NSArray<NSString *> *)packagesProvidingHeader:(NSString *)includeName
                                          distro:(NSString *)distro
                                           error:(NSError **)error
{
  if (!_db || !includeName || !distro)
    return @[];

  static const char *sql =
    "SELECT p.name "
    "FROM header h "
    "JOIN provider pr ON pr.header_id = h.id "
    "JOIN package p ON p.id = pr.package_id "
    "JOIN distro d ON d.id = p.distro_id "
    "WHERE h.include_name = ? AND d.name = ? "
    "ORDER BY p.name;";

  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) != SQLITE_OK)
    {
      if (error)
        *error = [self _queryError:@"Failed to prepare header lookup"];
      return @[];
    }

  sqlite3_bind_text(stmt, 1, [includeName UTF8String], -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 2, [distro UTF8String], -1, SQLITE_TRANSIENT);

  NSMutableArray *packages = [NSMutableArray array];
  while (sqlite3_step(stmt) == SQLITE_ROW)
    {
      const unsigned char *name = sqlite3_column_text(stmt, 0);
      if (name)
        [packages addObject:[NSString stringWithUTF8String:(const char *)name]];
    }

  sqlite3_finalize(stmt);

  NSLog(@"GWHeaderDatabase <- packagesProvidingHeader: %@ / %@ -> %@",
        includeName, distro, packages);
  return packages;
}

- (nullable NSString *)packageForHeader:(NSString *)includeName
                                 distro:(NSString *)distro
                                  error:(NSError **)error
{
  NSArray *packages = [self packagesProvidingHeader:includeName
                                             distro:distro
                                              error:error];
  if ([packages count] == 0)
    {
      // Headers may be referenced without their directory prefix
      // ("#include <gphoto2.h>" instead of "<gphoto2/gphoto2.h>"), reachable
      // via a -I subdirectory flag.  Resolve by basename, but only when it
      // maps to exactly one package: common basenames like "config.h" are
      // ambiguous and must stay unresolved.
      NSArray *byBasename = [self _packagesForHeaderBasename:
                             [includeName lastPathComponent]
                                                      distro:distro
                                                       error:error];
      if ([byBasename count] == 1)
        {
          NSLog(@"GWHeaderDatabase <- packageForHeader: %@ / %@ -> %@ (basename match)",
                includeName, distro, byBasename[0]);
          return byBasename[0];
        }
      if ([byBasename count] > 1)
        {
          NSLog(@"GWHeaderDatabase <- packageForHeader: %@ / %@ -> ambiguous "
                "basename (%lu packages)", includeName, distro,
                (unsigned long)[byBasename count]);
        }
      return nil;
    }

  // Best name match: prefer packages whose (normalized) name equals or
  // contains the header's top-level directory, e.g. header "gphoto2/gphoto2.h"
  // -> package "libgphoto2" over an unrelated package that also ships the
  // header.  Ties are broken by shortest name, then alphabetically.
  NSString *key = [self _matchKeyForHeader:includeName];
  NSString *normalizedKey = [self _normalizePackageName:key];

  NSString *best = nil;
  NSInteger bestScore = -1;

  for (NSString *candidate in packages)
    {
      NSInteger score = 0;
      if ([self _packageName:candidate containsWord:key])
        score += 100;
      if (normalizedKey && [normalizedKey isEqualToString:[self _normalizePackageName:candidate]])
        score += 50;

      if (score > bestScore
          || (score == bestScore && best && [candidate length] < [best length])
          || (score == bestScore && best && [candidate length] == [best length]
              && [candidate compare:best] == NSOrderedAscending))
        {
          best = candidate;
          bestScore = score;
        }
    }

  if (!best)
    best = packages[0];

  NSLog(@"GWHeaderDatabase <- packageForHeader: %@ / %@ -> %@", includeName, distro, best);
  return best;
}

- (BOOL)isHeaderInstalled:(NSString *)includeName
                   distro:(NSString *)distro
{
  if (!_db || !includeName || !distro)
    return NO;

  NSString *prefix = [self _includePrefixForDistro:distro];
  if (!prefix)
    return NO;

  NSString *installedPath = [@"/" stringByAppendingString:
      [prefix stringByAppendingString:includeName]];
  if ([[NSFileManager defaultManager] fileExistsAtPath:installedPath])
    {
      NSLog(@"GWHeaderDatabase <- isHeaderInstalled: %@ / %@ -> YES (%@)",
            includeName, distro, installedPath);
      return YES;
    }

  // The header may be reachable via a -I subdirectory flag even though its
  // canonical path does not exist, e.g. "#include <gphoto2.h>" with
  // -I/usr/include/gphoto2.  Treat any file with the same basename anywhere
  // under the include prefix as installed.
  NSString *basename = [includeName lastPathComponent];
  BOOL found = [[self _installedBasenamesForDistro:distro] containsObject:basename];
  NSLog(@"GWHeaderDatabase <- isHeaderInstalled: %@ / %@ -> %d (%@ via basename)",
        includeName, distro, found, installedPath);
  return found;
}

#pragma mark - Internal Helpers

- (nullable NSString *)_includePrefixForDistro:(NSString *)distro
{
  static const char *sql =
    "SELECT include_prefix FROM distro WHERE name = ?;";

  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) != SQLITE_OK)
    return nil;

  sqlite3_bind_text(stmt, 1, [distro UTF8String], -1, SQLITE_TRANSIENT);

  NSString *prefix = nil;
  if (sqlite3_step(stmt) == SQLITE_ROW)
    {
      const unsigned char *text = sqlite3_column_text(stmt, 0);
      if (text)
        prefix = [NSString stringWithUTF8String:(const char *)text];
    }

  sqlite3_finalize(stmt);
  return prefix;
}

// Distinct packages whose (unprefixed) header basename matches.  Used as a
// fallback for headers referenced without their directory prefix.
- (NSArray<NSString *> *)_packagesForHeaderBasename:(NSString *)basename
                                             distro:(NSString *)distro
                                              error:(NSError **)error
{
  if (!_db || !basename || !distro)
    return @[];

  static const char *sql =
    "SELECT DISTINCT p.name "
    "FROM header h "
    "JOIN provider pr ON pr.header_id = h.id "
    "JOIN package p ON p.id = pr.package_id "
    "JOIN distro d ON d.id = p.distro_id "
    "WHERE h.basename = ? AND d.name = ? "
    "ORDER BY p.name;";

  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) != SQLITE_OK)
    {
      if (error)
        *error = [self _queryError:@"Failed to prepare basename lookup"];
      return @[];
    }

  sqlite3_bind_text(stmt, 1, [basename UTF8String], -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 2, [distro UTF8String], -1, SQLITE_TRANSIENT);

  NSMutableArray *packages = [NSMutableArray array];
  while (sqlite3_step(stmt) == SQLITE_ROW)
    {
      const unsigned char *name = sqlite3_column_text(stmt, 0);
      if (name)
        [packages addObject:[NSString stringWithUTF8String:(const char *)name]];
    }

  sqlite3_finalize(stmt);
  return packages;
}

// Every file basename present under the distro's include prefix, cached per
// instance.  Lets isHeaderInstalled: match headers that live in a
// subdirectory reached through a -I flag.
- (NSSet *)_installedBasenamesForDistro:(NSString *)distro
{
  if (!_installedBasenames)
    _installedBasenames = [NSMutableDictionary dictionary];

  NSSet *cached = _installedBasenames[distro];
  if (cached)
    return cached;

  NSString *prefix = [self _includePrefixForDistro:distro];
  NSMutableSet *basenames = [NSMutableSet set];
  if (prefix)
    {
      NSString *root = [@"/" stringByAppendingString:prefix];
      [self _collectHeaderBasenamesAtPath:root into:basenames];
    }
  _installedBasenames[distro] = basenames;
  return basenames;
}

- (void)_collectHeaderBasenamesAtPath:(NSString *)path
                                 into:(NSMutableSet *)basenames
{
  NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path
                                                                          error:NULL];
  for (NSString *name in contents)
    {
      NSString *child = [path stringByAppendingPathComponent:name];
      BOOL isDir = NO;
      if (![[NSFileManager defaultManager] fileExistsAtPath:child isDirectory:&isDir])
        continue;

      if (isDir)
        {
          // Do not descend into symlinked directories: they repeat trees that
          // are already covered and can form loops.
          NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:child error:NULL];
          if (attrs && [attrs fileType] == NSFileTypeSymbolicLink)
            continue;
          [self _collectHeaderBasenamesAtPath:child into:basenames];
        }
      else
        {
          [basenames addObject:name];
        }
    }
}

// The name component a package is expected to match: the top-level directory
// of the include ("gphoto2" for "gphoto2/gphoto2.h"), or the basename stem
// for headers at the include root ("zlib" for "zlib.h").
- (NSString *)_matchKeyForHeader:(NSString *)includeName
{
  NSRange slash = [includeName rangeOfString:@"/"];
  NSString *component = (slash.location == NSNotFound)
    ? [[includeName lastPathComponent] stringByDeletingPathExtension]
    : [includeName substringToIndex:slash.location];
  return component;
}

- (NSString *)_normalizePackageName:(NSString *)name
{
  NSMutableString *n = [[name lowercaseString] mutableCopy];

  // Strip common prefixes/suffixes that do not belong to the header's name.
  if ([n hasPrefix:@"lib"])
    [n deleteCharactersInRange:NSMakeRange(0, 3)];

  static NSRegularExpression *suffixRegex = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    suffixRegex = [NSRegularExpression
      regularExpressionWithPattern:@"(-dev|-devel|-static|-dbg|-tools|-docs|-headers|-d)$"
                           options:NSRegularExpressionCaseInsensitive
                             error:NULL];
  });
  [suffixRegex replaceMatchesInString:n
                              options:0
                                range:NSMakeRange(0, [n length])
                           withTemplate:@""];

  // "-dev0", "-dev1", "-1.2.3" style trailing suffixes.
  static NSRegularExpression *versionSuffixRegex = nil;
  static dispatch_once_t onceToken2;
  dispatch_once(&onceToken2, ^{
    versionSuffixRegex = [NSRegularExpression
      regularExpressionWithPattern:@"(-?dev?[0-9]*|-?[0-9][0-9.]*)$"
                           options:NSRegularExpressionCaseInsensitive
                             error:NULL];
  });
  [versionSuffixRegex replaceMatchesInString:n
                                     options:0
                                       range:NSMakeRange(0, [n length])
                                  withTemplate:@""];

  // Compare without separators: "gstreamer-1.0" vs "gstreamer1.0".
  [n replaceOccurrencesOfString:@"-"
                     withString:@""
                        options:0
                          range:NSMakeRange(0, [n length])];
  [n replaceOccurrencesOfString:@"_"
                     withString:@""
                        options:0
                          range:NSMakeRange(0, [n length])];
  return n;
}

// Whole-word containment of key within name, case-insensitive, treating
// '-' and '_' as word characters so "libgphoto2" contains "gphoto2" but
// "libgphoto2policy" is not an accidental match for "gphoto2".
- (BOOL)_packageName:(NSString *)name containsWord:(NSString *)key
{
  if ([key length] == 0)
    return NO;

  NSString *lowerName = [name lowercaseString];
  NSString *lowerKey = [key lowercaseString];

  NSRange r = [lowerName rangeOfString:lowerKey];
  while (r.location != NSNotFound)
    {
      BOOL beforeOk = (r.location == 0);
      if (!beforeOk)
        {
          unichar c = [lowerName characterAtIndex:r.location - 1];
          beforeOk = !isalnum(c) && c != '-' && c != '_';
        }
      NSUInteger end = r.location + r.length;
      BOOL afterOk = (end >= [lowerName length]);
      if (!afterOk)
        {
          unichar c = [lowerName characterAtIndex:end];
          afterOk = !isalnum(c) && c != '-' && c != '_';
        }
      if (beforeOk && afterOk)
        return YES;

      r = [lowerName rangeOfString:lowerKey
                           options:0
                             range:NSMakeRange(r.location + 1,
                                               [lowerName length] - r.location - 1)];
    }
  return NO;
}

- (NSError *)_queryError:(NSString *)message
{
  return [NSError errorWithDomain:GWPackageManagerErrorDomain
                            code:GWPackageManagerErrorDatabaseUnavailable
                        userInfo:@{ NSLocalizedDescriptionKey: message }];
}

@end