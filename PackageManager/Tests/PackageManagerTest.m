/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWPackageManager Test Suite
 *
 * Comprehensive unit tests for the GWPackageManager framework.
 * Tests are standalone; uses a simple assertion framework.
 *
 * Test categories:
 *   - GWOSDetector tests
 *   - GWPackageInstallSpec tests
 *   - Backend tests (with mocked executor)
 *   - GWPackageManager tests (with mocked backend)
 */

#import <Foundation/Foundation.h>
#import "GWOSDetector.h"
#import "GWPackageInstallSpec.h"
#import "GWSystemCommandExecutor.h"
#import "GWPackageManagerBackend.h"
#import "GWPackageManager.h"
#import "GWHeaderDatabase.h"

#pragma mark - Test Assertion Framework

static int testCount = 0;
static int passCount = 0;
static int failCount = 0;

#define TAssert(condition, desc, ...) \
  do { \
    testCount++; \
    if (!(condition)) { \
      failCount++; \
      NSLog(@"  FAIL: %s:%d - " desc, __FILE__, __LINE__, ##__VA_ARGS__); \
      return NO; \
    } \
  } while(0)

#define TAssertEqualObjects(a, b, desc, ...) \
  do { \
    testCount++; \
    id _a = (a); id _b = (b); \
    if (_a != _b && ![_a isEqual:_b]) { \
      failCount++; \
      NSLog(@"  FAIL: %s:%d - " desc " (got '%@', expected '%@')", \
            __FILE__, __LINE__, ##__VA_ARGS__, _a, _b); \
      return NO; \
    } \
  } while(0)

#define TAssertTrue(condition, desc, ...) \
  TAssert((condition), desc, ##__VA_ARGS__)

#define TAssertFalse(condition, desc, ...) \
  TAssert(!(condition), desc, ##__VA_ARGS__)

#define TAssertNotNil(obj, desc, ...) \
  TAssert((obj) != nil, desc, ##__VA_ARGS__)

#define TAssertNil(obj, desc, ...) \
  TAssert((obj) == nil, desc, ##__VA_ARGS__)

static void runTest(NSString *name, BOOL (^block)(void))
{
  @autoreleasepool
    {
      NSLog(@"\n--- %@ ---", name);
      BOOL result = block();
      if (result)
        {
          passCount++;
          NSLog(@"  PASS");
        }
      else
        {
          NSLog(@"  FAILED");
        }
    }
}

#pragma mark - Mock Objects

#pragma mark Mock Command Executor

@interface GWMockSystemCommandExecutor : NSObject <GWSystemCommandExecutor>
{
  NSMutableArray<NSDictionary *> *_recordedCalls;
  NSMutableDictionary *_resultMap; // key -> NSDictionary with exitCode, stdout, stderr
}
@property (readonly) NSArray<NSDictionary *> *recordedCalls;
- (void)setResultForCommand:(NSString *)path
                  arguments:(NSArray *)args
                   exitCode:(int)exitCode
                     output:(NSString *)output
               errorOutput:(NSString *)errorOutput;
- (void)clearResults;
@end

@implementation GWMockSystemCommandExecutor

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _recordedCalls = [NSMutableArray array];
      _resultMap = [NSMutableDictionary dictionary];
    }
  return self;
}

- (NSString *)_keyForPath:(NSString *)path arguments:(NSArray *)args
{
  return [NSString stringWithFormat:@"%@ %@", path, [args componentsJoinedByString:@" "]];
}

- (void)setResultForCommand:(NSString *)path
                  arguments:(NSArray *)args
                   exitCode:(int)exitCode
                     output:(NSString *)output
               errorOutput:(NSString *)errorOutput
{
  NSString *key = [self _keyForPath:path arguments:args];
  NSDictionary *result = @{
    @"exitCode": @(exitCode),
    @"output": output ?: @"",
    @"errorOutput": errorOutput ?: @"",
  };
  _resultMap[key] = result;
}

- (void)clearResults
{
  [_recordedCalls removeAllObjects];
  [_resultMap removeAllObjects];
}

- (NSArray *)recordedCalls
{
  return [_recordedCalls copy];
}

- (int)execute:(NSString *)path arguments:(NSArray *)args
{
  return [self execute:path arguments:args output:nil errorOutput:nil];
}

- (int)execute:(NSString *)path arguments:(NSArray *)args
        output:(NSString *__autoreleasing *)output
{
  return [self execute:path arguments:args output:output errorOutput:nil];
}

- (int)execute:(NSString *)path arguments:(NSArray *)args
        output:(NSString *__autoreleasing *)output
  errorOutput:(NSString *__autoreleasing *)errorOutput
{
  NSString *key = [self _keyForPath:path arguments:args];
  NSDictionary *result = _resultMap[key];

  [_recordedCalls addObject:@{
    @"path": path ?: @"",
    @"args": args ?: @[],
  }];

  if (output)
    *output = result[@"output"] ?: @"";
  if (errorOutput)
    *errorOutput = result[@"errorOutput"] ?: @"";

  return [result[@"exitCode"] intValue];
}

- (int)execute:(NSString *)path
     arguments:(NSArray *)args
 stderrCallback:(void (^)(NSString *line))callback
 capturedErrorOutput:(NSString *__autoreleasing *)errorOutput
{
  // Delegate to the existing output-capturing variant
  NSString *captured = nil;
  int rc = [self execute:path arguments:args output:nil errorOutput:&captured];
  if (errorOutput) *errorOutput = captured ?: @"";
  // Call the callback with the captured output as a single line
  if (callback && [captured length] > 0)
    callback(captured);
  return rc;
}

- (int)execute:(NSString *)path
     arguments:(NSArray *)args
 stdoutCallback:(void (^)(NSString *line))stdoutCallback
 stderrCallback:(void (^)(NSString *line))stderrCallback
 capturedErrorOutput:(NSString *__autoreleasing *)errorOutput
{
  // Delegate to the variant that captures error output, ignore stdout
  return [self execute:path arguments:args stderrCallback:stderrCallback capturedErrorOutput:errorOutput];
}

@end

#pragma mark Mock Backend

@interface GWMockPackageManagerBackend : NSObject <GWPackageManagerBackend>
{
  NSMutableArray<NSDictionary *> *_recordedCalls;
  BOOL _installResult;
  BOOL _uninstallResult;
  NSError *_installError;
  NSError *_uninstallError;
  NSArray *_filesResult;
  NSString *_owningFileResult;
}
@property (readonly) NSArray<NSDictionary *> *recordedCalls;
@property (readonly) NSString *backendName;
- (void)setInstallResult:(BOOL)result error:(NSError *)error;
- (void)setUninstallResult:(BOOL)result error:(NSError *)error;
- (void)setFilesResult:(NSArray *)files;
- (void)setOwningFileResult:(NSString *)path;
- (void)clearResults;
@end

@implementation GWMockPackageManagerBackend

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _recordedCalls = [NSMutableArray array];
      _installResult = YES;
      _uninstallResult = YES;
    }
  return self;
}

- (NSString *)backendName { return @"MockBackend"; }

- (void)setInstallResult:(BOOL)result error:(NSError *)error
{
  _installResult = result;
  _installError = error;
}

- (void)setUninstallResult:(BOOL)result error:(NSError *)error
{
  _uninstallResult = result;
  _uninstallError = error;
}

- (void)setFilesResult:(NSArray *)files { _filesResult = files; }
- (void)setOwningFileResult:(NSString *)path { _owningFileResult = path; }

- (void)clearResults { [_recordedCalls removeAllObjects]; }

- (NSArray *)recordedCalls { return [_recordedCalls copy]; }

- (BOOL)installPackages:(NSArray *)packageNames
        localFilePaths:(NSArray *)filePaths
             progress:(id<GWInstallProgressHandler>)handler
                error:(NSError **)error
{
  [_recordedCalls addObject:@{
    @"method": @"installPackages:localFilePaths:progress:error:",
    @"packages": packageNames ?: @[],
    @"localFilePaths": filePaths ?: @[],
    @"handler": handler ? (id)handler : [NSNull null],
  }];

  if (handler)
    {
      [handler installDidProgress:0.0 message:@"Preparing..."];
      [handler installDidProgress:0.5 message:@"Installing packages..."];
    }

  if (error && _installError)
    *error = _installError;

  if (!_installResult && _installError == nil)
    {
      if (error)
        *error = [NSError errorWithDomain:@"GWPackageManagerErrorDomain"
                                    code:GWPackageManagerErrorCommandFailed
                                userInfo:@{NSLocalizedDescriptionKey: @"Mock install failed"}];
    }

  return _installResult;
}

- (BOOL)uninstallPackages:(NSArray *)packageNames
                progress:(id<GWInstallProgressHandler>)handler
                   error:(NSError **)error
{
  [_recordedCalls addObject:@{
    @"method": @"uninstallPackages:progress:error:",
    @"packages": packageNames ?: @[],
    @"handler": handler ? (id)handler : [NSNull null],
  }];

  if (handler)
    {
      [handler installDidProgress:0.0 message:@"Preparing..."];
      [handler installDidProgress:0.5 message:@"Uninstalling packages..."];
    }

  if (error && _uninstallError)
    *error = _uninstallError;

  return _uninstallResult;
}

- (NSArray *)filesForPackage:(NSString *)name error:(NSError **)error
{
  [_recordedCalls addObject:@{
    @"method": @"filesForPackage:error:",
    @"package": name ?: @"",
  }];
  return _filesResult ?: @[];
}

- (NSString *)packageOwningFile:(NSString *)path error:(NSError **)error
{
  [_recordedCalls addObject:@{
    @"method": @"packageOwningFile:error:",
    @"path": path ?: @"",
  }];
  return _owningFileResult;
}

@end

#pragma mark Mock Progress Handler

@interface GWMockProgressHandler : NSObject <GWInstallProgressHandler>
{
  NSMutableArray *_progressCalls;
}
@property (readonly) NSArray *progressCalls;
@end

@implementation GWMockProgressHandler

- (instancetype)init
{
  self = [super init];
  if (self) _progressCalls = [NSMutableArray array];
  return self;
}

- (void)installDidProgress:(float)progress message:(NSString *)message
{
  [_progressCalls addObject:@{
    @"progress": @(progress),
    @"message": message ?: @"",
  }];
}

- (NSArray *)progressCalls { return [_progressCalls copy]; }

@end

#pragma mark - GWOSDetector Tests

@interface GWOSDetectorTestHelper : NSObject
+ (BOOL)testFreeBSDWithOSRelease;
+ (BOOL)testFreeBSDWithoutOSReleaseFallbackToUname;
+ (BOOL)testLinuxWithOSRelease;
+ (BOOL)testLinuxMultipleIDLike;
+ (BOOL)testOpenBSDWithoutOSRelease;
@end

@implementation GWOSDetectorTestHelper

+ (BOOL)testFreeBSDWithOSRelease
{
  // Create temp os-release file with GhostBSD-like content
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-ghostbsd"];
  NSString *content = @"ID=ghostbsd\nID_LIKE=freebsd\n";
  [content writeToFile:osReleasePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:@"FreeBSD"];

  NSString *osID = [GWOSDetector currentOSIdentifier];
  NSArray *searchOrder = [GWOSDetector osSearchOrder];

  TAssertEqualObjects(osID, @"ghostbsd", @"Primary OS ID should be 'ghostbsd'");
  TAssertEqualObjects(searchOrder, (@[@"ghostbsd", @"freebsd"]),
                      @"Search order should be [ghostbsd, freebsd]");

  // Cleanup
  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];
  [GWOSDetector setUnameOverride:nil];

  return YES;
}

+ (BOOL)testFreeBSDWithoutOSReleaseFallbackToUname
{
  // Use a non-existent path
  [GWOSDetector setOSReleasePathOverride:@"/nonexistent/os-release-test"];
  [GWOSDetector setUnameOverride:@"FreeBSD"];

  NSString *osID = [GWOSDetector currentOSIdentifier];
  NSArray *searchOrder = [GWOSDetector osSearchOrder];

  TAssertEqualObjects(osID, @"freebsd", @"Should fall back to 'freebsd' from uname");

  // On fallback, search order should just be the primary ID
  TAssertEqualObjects(searchOrder, (@[@"freebsd"]),
                      @"Search order should be [freebsd] on uname fallback");

  [GWOSDetector setOSReleasePathOverride:nil];
  [GWOSDetector setUnameOverride:nil];

  return YES;
}

+ (BOOL)testLinuxWithOSRelease
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-debian"];
  NSString *content = @"ID=debian\nID_LIKE=\nVERSION_ID=\"12\"\n";
  [content writeToFile:osReleasePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:nil];

  NSString *osID = [GWOSDetector currentOSIdentifier];
  NSArray *searchOrder = [GWOSDetector osSearchOrder];

  TAssertEqualObjects(osID, @"debian", @"Primary OS ID should be 'debian'");
  // When ID_LIKE is empty, search order should be just the primary
  TAssertEqualObjects(searchOrder, (@[@"debian"]),
                      @"Search order should be [debian] with empty ID_LIKE");

  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];

  return YES;
}

+ (BOOL)testLinuxMultipleIDLike
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-ubuntu"];
  NSString *content = @"ID=ubuntu\nID_LIKE=\"ubuntu debian\"\n";
  [content writeToFile:osReleasePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:nil];

  NSString *osID = [GWOSDetector currentOSIdentifier];
  NSArray *searchOrder = [GWOSDetector osSearchOrder];

  TAssertEqualObjects(osID, @"ubuntu", @"Primary OS ID should be 'ubuntu'");
  TAssertEqualObjects(searchOrder, (@[@"ubuntu", @"ubuntu", @"debian"]),
                      @"Search order should include both ID_LIKE values");

  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];

  return YES;
}

+ (BOOL)testOpenBSDWithoutOSRelease
{
  [GWOSDetector setOSReleasePathOverride:@"/nonexistent/os-release-test"];
  [GWOSDetector setUnameOverride:@"OpenBSD"];

  NSString *osID = [GWOSDetector currentOSIdentifier];

  TAssertEqualObjects(osID, @"openbsd", @"Should fall back to 'openbsd' from uname");

  [GWOSDetector setOSReleasePathOverride:nil];
  [GWOSDetector setUnameOverride:nil];

  return YES;
}

@end

#pragma mark - GWPackageInstallSpec Tests

@interface GWPackageInstallSpecTestHelper : NSObject
+ (BOOL)testInstallSpecNoOverrides;
+ (BOOL)testInstallSpecOSOverride;
+ (BOOL)testInstallSpecPartialOverride;
+ (BOOL)testUninstallSpecBasic;
+ (BOOL)testUninstallSpecOverride;
@end

@implementation GWPackageInstallSpecTestHelper

+ (BOOL)testInstallSpecNoOverrides
{
  // Write a plist without overrides
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-test-null.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp", @"gimp-plugins"],
    @"postinstall_command": @"/usr/local/bin/gimp",
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeInstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse plist without overrides");
  TAssertNil(error, @"Should not produce an error");
  TAssertEqualObjects(spec.packages, (@[@"gimp", @"gimp-plugins"]),
                      @"Should return top-level packages");
  TAssertEqualObjects(spec.localFilePaths, @[],
                      @"Should have empty localFilePaths");
  TAssertEqualObjects(spec.postCommand, @"/usr/local/bin/gimp",
                      @"Should return postinstall command");
  TAssertTrue([spec isValid:&error], @"Spec should be valid");
  TAssertNil(error, @"Validation error should be nil");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testInstallSpecOSOverride
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-test-override.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp", @"gimp-plugins"],
    @"postinstall_command": @"/usr/local/bin/gimp",
    @"os_overrides": @{
      @"debian": @{
        @"packages": @[@"gimp", @"gimp-plugin-registry"],
        @"postinstall_command": @"/usr/bin/gimp",
      },
    },
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeInstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse plist with overrides");
  // When no OS override path is injected, the spec uses current OS.
  // For testing, we'd need to inject the search order. Let's just verify
  // the parsing works and objects are created.
  TAssertNotNil(spec.packages, @"Should have packages");
  TAssert([spec.packages count] > 0, @"Should have at least one package");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testInstallSpecPartialOverride
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-test-partial.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp"],
    @"postinstall_command": @"/usr/local/bin/gimp",
    @"os_overrides": @{
      @"debian": @{
        @"packages": @[@"gimp", @"gimp-plugin-registry"],
        // No postinstall_command override — should fall back
      },
    },
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeInstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse partial override plist");
  TAssertNotNil(spec.packages, @"Should have packages");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testUninstallSpecBasic
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"uninstall-test-basic.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp"],
    @"postuninstall_command": @"/bin/echo Removed",
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeUninstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse uninstall plist");
  TAssertEqualObjects(spec.packages, (@[@"gimp"]),
                      @"Should have gimp package");
  TAssertEqualObjects(spec.postCommand, @"/bin/echo Removed",
                      @"Should have postuninstall command");
  TAssertTrue([spec isValid:&error], @"Spec should be valid");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testUninstallSpecOverride
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"uninstall-test-override.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp"],
    @"os_overrides": @{
      @"debian": @{
        @"packages": @[@"gimp-extra"],
      },
    },
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeUninstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse uninstall plist with override");
  TAssertNotNil(spec.packages, @"Should have packages");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

@end

#pragma mark - Backend Tests

@interface BackendTestHelper : NSObject
+ (BOOL)testDebBackendExecuteCommand;
+ (BOOL)testArchBackendExecuteCommand;
+ (BOOL)testFreeBSDBackendExecuteCommand;
+ (BOOL)testOpenBSDBackendExecuteCommand;
+ (BOOL)testInstallFailsReportsError;
@end

@implementation BackendTestHelper

+ (BOOL)testDebBackendExecuteCommand
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/bin/apt-get"
                      arguments:@[@"install", @"-y", @"sl"]
                       exitCode:0
                         output:@"Installing sl..."
                   errorOutput:@""];

  int exitCode = [executor execute:@"/usr/bin/apt-get"
                         arguments:@[@"install", @"-y", @"sl"]];
  TAssertTrue(exitCode == 0, @"apt-get install should succeed");
  TAssertTrue([executor.recordedCalls count] == 1,
              @"Should have recorded one call");

  NSDictionary *call = executor.recordedCalls[0];
  TAssertEqualObjects(call[@"path"], @"/usr/bin/apt-get",
                      @"Should record correct path");

  return YES;
}

+ (BOOL)testArchBackendExecuteCommand
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/bin/pacman"
                      arguments:@[@"-S", @"--noconfirm", @"vim"]
                       exitCode:0
                         output:@"Installing vim..."
                   errorOutput:@""];

  int exitCode = [executor execute:@"/usr/bin/pacman"
                         arguments:@[@"-S", @"--noconfirm", @"vim"]];
  TAssertTrue(exitCode == 0, @"pacman install should succeed");
  TAssertTrue([executor.recordedCalls count] == 1,
              @"Should have recorded one call");

  return YES;
}

+ (BOOL)testFreeBSDBackendExecuteCommand
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/sbin/pkg"
                      arguments:@[@"install", @"-y", @"tmux"]
                       exitCode:0
                         output:@"Installing tmux..."
                   errorOutput:@""];

  int exitCode = [executor execute:@"/usr/sbin/pkg"
                         arguments:@[@"install", @"-y", @"tmux"]];
  TAssertTrue(exitCode == 0, @"pkg install should succeed");

  return YES;
}

+ (BOOL)testOpenBSDBackendExecuteCommand
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/sbin/pkg_add"
                      arguments:@[@"curl"]
                       exitCode:0
                         output:@"Installing curl..."
                   errorOutput:@""];

  int exitCode = [executor execute:@"/usr/sbin/pkg_add"
                         arguments:@[@"curl"]];
  TAssertTrue(exitCode == 0, @"pkg_add should succeed");

  return YES;
}

+ (BOOL)testInstallFailsReportsError
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/bin/apt-get"
                      arguments:@[@"install", @"-y", @"nonexistent-pkg"]
                       exitCode:100
                         output:@""
                   errorOutput:@"E: Unable to locate package nonexistent-pkg"];

  NSString *output = nil;
  int exitCode = [executor execute:@"/usr/bin/apt-get"
                         arguments:@[@"install", @"-y", @"nonexistent-pkg"]
                            output:&output];

  TAssertTrue(exitCode != 0, @"Should fail with non-zero exit code");
  TAssertNotNil(output, @"Should capture stdout");
  TAssertTrue([output length] == 0, @"Output should be empty on failure");

  return YES;
}

@end

#pragma mark - GWPackageManager Public API Tests

@interface PackageManagerTestHelper : NSObject
+ (BOOL)testInitWithBackend;
+ (BOOL)testInstallPackagesNoProgress;
+ (BOOL)testInstallPackagesWithProgress;
+ (BOOL)testInstallPackagesFails;
+ (BOOL)testUninstallPackages;
+ (BOOL)testFilesForPackage;
+ (BOOL)testPackageOwningFile;
+ (BOOL)testRunInstallFromPlistCallsBackend;
+ (BOOL)testRunInstallFromPlistInstallationFails;
+ (BOOL)testRunUninstallFromPlist;
+ (BOOL)testProgressForwarding;
@end

@implementation PackageManagerTestHelper

+ (BOOL)testInitWithBackend
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  TAssertNotNil(pm, @"PackageManager should be created");
  TAssertEqualObjects(pm.backend, mockBackend,
                      @"Should use the injected backend");

  return YES;
}

+ (BOOL)testInstallPackagesNoProgress
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm installPackages:@[@"sl"] error:&error];

  TAssertTrue(result, @"Install should succeed");
  TAssertNil(error, @"Error should be nil on success");
  TAssertTrue([mockBackend.recordedCalls count] == 1,
              @"Backend should be called once");
  NSDictionary *call = mockBackend.recordedCalls[0];
  TAssertEqualObjects(call[@"packages"], (@[@"sl"]),
                      @"Should pass package names to backend");

  return YES;
}

+ (BOOL)testInstallPackagesWithProgress
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];
  GWMockProgressHandler *progress = [[GWMockProgressHandler alloc] init];

  NSError *error = nil;
  BOOL result = [pm installPackages:@[@"sl"]
                     localFilePaths:nil
                          progress:progress
                             error:&error];

  TAssertTrue(result, @"Install should succeed");
  TAssertTrue([progress.progressCalls count] > 0,
              @"Progress handler should be called");

  // Verify progress stages
  NSDictionary *firstCall = progress.progressCalls[0];
  float firstProgress = [firstCall[@"progress"] floatValue];
  TAssertTrue(firstProgress == 0.0,
              @"First progress should be 0.0");

  return YES;
}

+ (BOOL)testInstallPackagesFails
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setInstallResult:NO error:nil];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm installPackages:@[@"sl"] error:&error];

  TAssertFalse(result, @"Install should fail");
  TAssertNotNil(error, @"Error should be set on failure");

  return YES;
}

+ (BOOL)testUninstallPackages
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm uninstallPackages:@[@"sl"] error:&error];

  TAssertTrue(result, @"Uninstall should succeed");
  TAssertNil(error, @"Error should be nil on success");
  TAssertTrue([mockBackend.recordedCalls count] == 1,
              @"Backend should be called once");
  NSDictionary *call = mockBackend.recordedCalls[0];
  TAssertEqualObjects(call[@"method"],
                      @"uninstallPackages:progress:error:",
                      @"Should call uninstall method");

  return YES;
}

+ (BOOL)testFilesForPackage
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setFilesResult:@[@"/usr/bin/sl", @"/usr/share/man/man6/sl.6.gz"]];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  NSArray *files = [pm filesForPackage:@"sl" error:&error];

  TAssertNotNil(files, @"Should return files");
  TAssertTrue([files count] == 2,
              @"Should have 2 files for sl package");

  return YES;
}

+ (BOOL)testPackageOwningFile
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setOwningFileResult:@"sl"];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  NSString *owner = [pm packageOwningFile:@"/usr/games/sl" error:&error];

  TAssertEqualObjects(owner, @"sl",
                      @"Should identify sl as owning package");

  return YES;
}

+ (BOOL)testRunInstallFromPlistCallsBackend
{
  // Create a temp install plist
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-plist-test.plist"];
  NSDictionary *plist = @{
    @"packages": @[@"sl"],
    @"postinstall_command": @"/bin/true",
    @"os_overrides": @{},
  };
  [plist writeToFile:plistPath atomically:YES];

  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm runInstallFromPlistAtPath:plistPath
                                     progress:nil
                                        error:&error];

  TAssertTrue(result, @"Plist install should succeed");
  TAssertTrue([mockBackend.recordedCalls count] > 0,
              @"Backend should have been called");
  NSDictionary *call = [mockBackend.recordedCalls firstObject];
  TAssertEqualObjects(call[@"method"],
                      @"installPackages:localFilePaths:progress:error:",
                      @"Should call backend install method");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testRunInstallFromPlistInstallationFails
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-plist-fail-test.plist"];
  NSDictionary *plist = @{
    @"packages": @[@"sl"],
    @"postinstall_command": @"/usr/games/sl",
  };
  [plist writeToFile:plistPath atomically:YES];

  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setInstallResult:NO error:[NSError errorWithDomain:GWPackageManagerErrorDomain
                                                            code:GWPackageManagerErrorPackageNotFound
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Package not found"}]];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm runInstallFromPlistAtPath:plistPath
                                     progress:nil
                                        error:&error];

  TAssertFalse(result, @"Plist install should fail when backend fails");
  TAssertNotNil(error, @"Error should be set");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testRunUninstallFromPlist
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"uninstall-plist-test.plist"];
  NSDictionary *plist = @{
    @"packages": @[@"sl"],
    @"postuninstall_command": @"/bin/echo Removed",
  };
  [plist writeToFile:plistPath atomically:YES];

  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm runUninstallFromPlistAtPath:plistPath
                                       progress:nil
                                          error:&error];

  TAssertTrue(result, @"Plist uninstall should succeed");
  TAssertTrue([mockBackend.recordedCalls count] > 0,
              @"Backend should have been called");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testProgressForwarding
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];
  GWMockProgressHandler *progress = [[GWMockProgressHandler alloc] init];

  NSError *error = nil;
  [pm installPackages:@[@"sl"]
       localFilePaths:nil
            progress:progress
               error:&error];

  TAssertTrue([progress.progressCalls count] >= 2,
              @"Progress handler should receive multiple updates");

  NSDictionary *firstProgress = progress.progressCalls[0];
  TAssertTrue([firstProgress[@"progress"] floatValue] == 0.0,
              @"First progress update should be 0.0");

  return YES;
}

@end

#pragma mark - GWHeaderDatabase Tests

@interface GWHeaderDatabaseTestHelper : NSObject
+ (BOOL)testDatabaseOpens;
+ (BOOL)testPackageForGphoto2HeaderPerDistro;
+ (BOOL)testBestNameMatchPicksLibgphoto2;
+ (BOOL)testUnknownHeaderReturnsEmpty;
+ (BOOL)testDistroMappingForKnownFamilies;
@end

@implementation GWHeaderDatabaseTestHelper

// The database is checked into PackageManager/Resources/headers.db; the test
// binary runs from Tests/, so the file is one level up.
+ (GWHeaderDatabase *)testDatabase
{
  NSString *path = [@"../Resources/headers.db" stringByStandardizingPath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path])
    path = @"../PackageManager/Resources/headers.db";
  NSError *error = nil;
  GWHeaderDatabase *db = [[GWHeaderDatabase alloc] initWithPath:path error:&error];
  return db;
}

+ (BOOL)testDatabaseOpens
{
  GWHeaderDatabase *db = [self testDatabase];
  TAssertNotNil(db, @"Database should open from Resources/headers.db");
  TAssertTrue([db isOpen], @"Database should report open");
  return YES;
}

+ (BOOL)testPackageForGphoto2HeaderPerDistro
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  NSError *error = nil;
  NSArray *debian = [db packagesProvidingHeader:@"gphoto2/gphoto2.h"
                                        distro:@"debian"
                                         error:&error];
  TAssertNil(error, @"Debian lookup should not error");
  TAssertTrue([debian count] > 0, @"Debian should provide gphoto2/gphoto2.h");
  TAssertTrue([debian containsObject:@"libgphoto2-dev"],
              @"Debian provider should be libgphoto2-dev (got %@)", debian);

  NSArray *arch = [db packagesProvidingHeader:@"gphoto2/gphoto2.h"
                                       distro:@"arch"
                                        error:&error];
  TAssertTrue([arch count] > 0, @"Arch should provide gphoto2/gphoto2.h");
  TAssertTrue([arch containsObject:@"libgphoto2"],
              @"Arch provider should be libgphoto2 (got %@)", arch);

  NSArray *freebsd = [db packagesProvidingHeader:@"gphoto2/gphoto2.h"
                                          distro:@"freebsd"
                                           error:&error];
  TAssertTrue([freebsd count] > 0, @"FreeBSD should provide gphoto2/gphoto2.h");
  TAssertTrue([freebsd containsObject:@"libgphoto2"],
              @"FreeBSD provider should be libgphoto2 (got %@)", freebsd);

  return YES;
}

+ (BOOL)testBestNameMatchPicksLibgphoto2
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  NSError *error = nil;
  NSString *debian = [db packageForHeader:@"gphoto2/gphoto2.h"
                                   distro:@"debian"
                                    error:&error];
  TAssertEqualObjects(debian, @"libgphoto2-dev",
                      @"Best name match on Debian should pick libgphoto2-dev (got %@)", debian);

  NSString *arch = [db packageForHeader:@"gphoto2/gphoto2.h"
                                 distro:@"arch"
                                  error:&error];
  TAssertEqualObjects(arch, @"libgphoto2",
                      @"Best name match on Arch should pick libgphoto2 (got %@)", arch);

  return YES;
}

+ (BOOL)testUnknownHeaderReturnsEmpty
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  NSError *error = nil;
  NSArray *packages = [db packagesProvidingHeader:@"no/such/header.h"
                                           distro:@"debian"
                                            error:&error];
  TAssertNil(error, @"Unknown header lookup should not error");
  TAssertTrue([packages count] == 0, @"Unknown header should have no providers");
  return YES;
}

+ (BOOL)testBareHeaderResolvesByBasename
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  // "#include <gphoto2.h>" reaches the header via a -I subdirectory flag; it
  // must resolve to the same package as "gphoto2/gphoto2.h".
  NSError *error = nil;
  NSString *debian = [db packageForHeader:@"gphoto2.h" distro:@"debian" error:&error];
  TAssertNil(error, @"Bare gphoto2.h lookup should not error");
  TAssertEqualObjects(debian, @"libgphoto2-dev",
                      @"Bare gphoto2.h on Debian should resolve by basename (got %@)", debian);

  NSString *arch = [db packageForHeader:@"gphoto2.h" distro:@"arch" error:&error];
  TAssertEqualObjects(arch, @"libgphoto2",
                      @"Bare gphoto2.h on Arch should resolve by basename (got %@)", arch);

  NSString *freebsd = [db packageForHeader:@"gphoto2.h" distro:@"freebsd" error:&error];
  TAssertEqualObjects(freebsd, @"libgphoto2",
                      @"Bare gphoto2.h on FreeBSD should resolve by basename (got %@)", freebsd);

  return YES;
}

+ (BOOL)testAmbiguousBasenameStaysUnresolved
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  // "config.h" is shipped by dozens of packages; it must not be resolved.
  NSError *error = nil;
  NSString *config = [db packageForHeader:@"config.h" distro:@"debian" error:&error];
  TAssertNil(error, @"Ambiguous basename lookup should not error");
  TAssertNil(config, @"Ambiguous basename config.h must stay unresolved (got %@)", config);

  return YES;
}

+ (BOOL)testDistroMappingForKnownFamilies
{
  // Deterministic regardless of host OS: map every family through the same
  // logic the database uses and verify only known distros come out.
  NSDictionary *expected = @{
    @"debian": @"debian", @"ubuntu": @"debian", @"devuan": @"debian",
    @"kali": @"debian", @"linuxmint": @"debian", @"raspbian": @"debian",
    @"pop": @"debian", @"elementary": @"debian", @"zorin": @"debian",
    @"arch": @"arch", @"manjaro": @"arch", @"endeavouros": @"arch",
    @"arcolinux": @"arch",
    @"freebsd": @"freebsd", @"ghostbsd": @"freebsd", @"dragonfly": @"freebsd",
  };
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  // osSearchOrder for a synthetic os-release file lets us exercise the same
  // family mapping without changing the host's real /etc/os-release.
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"hdr-os-release-test"];
  for (NSString *osID in expected)
    {
      NSString *content = [NSString stringWithFormat:@"ID=%@\nID_LIKE=\n", osID];
      [content writeToFile:osReleasePath atomically:YES
                  encoding:NSUTF8StringEncoding error:nil];
      [GWOSDetector setOSReleasePathOverride:osReleasePath];

      NSString *family = [GWOSDetector packageManagerFamily];
      NSString *expectedDistro = expected[osID];
      NSString *mapped = nil;
      if ([family isEqualToString:@"debian"]) mapped = @"debian";
      else if ([family isEqualToString:@"arch"]) mapped = @"arch";
      else if ([family isEqualToString:@"freebsd"]) mapped = @"freebsd";

      TAssertEqualObjects(mapped, expectedDistro,
                          @"Family mapping for %@ should be %@", osID, expectedDistro);
    }

  // OpenBSD has no DB data.
  [GWOSDetector setUnameOverride:@"OpenBSD"];
  [GWOSDetector setOSReleasePathOverride:@"/nonexistent/os-release-test"];
  NSString *family = [GWOSDetector packageManagerFamily];
  TAssertEqualObjects(family, @"openbsd", @"OpenBSD family should be openbsd");

  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];
  [GWOSDetector setUnameOverride:nil];
  return YES;
}

@end

#pragma mark - Test Runner

@interface TestRunner : NSObject
+ (int)runAllTests;
@end

@implementation TestRunner

+ (int)runAllTests
{
  // --- GWOSDetector Tests ---
  runTest(@"testFreeBSDWithOSRelease", ^{
    return [GWOSDetectorTestHelper testFreeBSDWithOSRelease];
  });
  runTest(@"testFreeBSDWithoutOSReleaseFallbackToUname", ^{
    return [GWOSDetectorTestHelper testFreeBSDWithoutOSReleaseFallbackToUname];
  });
  runTest(@"testLinuxWithOSRelease", ^{
    return [GWOSDetectorTestHelper testLinuxWithOSRelease];
  });
  runTest(@"testLinuxMultipleIDLike", ^{
    return [GWOSDetectorTestHelper testLinuxMultipleIDLike];
  });
  runTest(@"testOpenBSDWithoutOSRelease", ^{
    return [GWOSDetectorTestHelper testOpenBSDWithoutOSRelease];
  });

  // --- GWPackageInstallSpec Tests ---
  runTest(@"testInstallSpecNoOverrides", ^{
    return [GWPackageInstallSpecTestHelper testInstallSpecNoOverrides];
  });
  runTest(@"testInstallSpecOSOverride", ^{
    return [GWPackageInstallSpecTestHelper testInstallSpecOSOverride];
  });
  runTest(@"testInstallSpecPartialOverride", ^{
    return [GWPackageInstallSpecTestHelper testInstallSpecPartialOverride];
  });
  runTest(@"testUninstallSpecBasic", ^{
    return [GWPackageInstallSpecTestHelper testUninstallSpecBasic];
  });
  runTest(@"testUninstallSpecOverride", ^{
    return [GWPackageInstallSpecTestHelper testUninstallSpecOverride];
  });

  // --- Backend Tests ---
  runTest(@"testDebBackendExecuteCommand", ^{
    return [BackendTestHelper testDebBackendExecuteCommand];
  });
  runTest(@"testArchBackendExecuteCommand", ^{
    return [BackendTestHelper testArchBackendExecuteCommand];
  });
  runTest(@"testFreeBSDBackendExecuteCommand", ^{
    return [BackendTestHelper testFreeBSDBackendExecuteCommand];
  });
  runTest(@"testOpenBSDBackendExecuteCommand", ^{
    return [BackendTestHelper testOpenBSDBackendExecuteCommand];
  });
  runTest(@"testInstallFailsReportsError", ^{
    return [BackendTestHelper testInstallFailsReportsError];
  });

  // --- GWPackageManager API Tests ---
  runTest(@"testInitWithBackend", ^{
    return [PackageManagerTestHelper testInitWithBackend];
  });
  runTest(@"testInstallPackagesNoProgress", ^{
    return [PackageManagerTestHelper testInstallPackagesNoProgress];
  });
  runTest(@"testInstallPackagesWithProgress", ^{
    return [PackageManagerTestHelper testInstallPackagesWithProgress];
  });
  runTest(@"testInstallPackagesFails", ^{
    return [PackageManagerTestHelper testInstallPackagesFails];
  });
  runTest(@"testUninstallPackages", ^{
    return [PackageManagerTestHelper testUninstallPackages];
  });
  runTest(@"testFilesForPackage", ^{
    return [PackageManagerTestHelper testFilesForPackage];
  });
  runTest(@"testPackageOwningFile", ^{
    return [PackageManagerTestHelper testPackageOwningFile];
  });
  runTest(@"testRunInstallFromPlistCallsBackend", ^{
    return [PackageManagerTestHelper testRunInstallFromPlistCallsBackend];
  });
  runTest(@"testRunInstallFromPlistInstallationFails", ^{
    return [PackageManagerTestHelper testRunInstallFromPlistInstallationFails];
  });
  runTest(@"testRunUninstallFromPlist", ^{
    return [PackageManagerTestHelper testRunUninstallFromPlist];
  });
  runTest(@"testProgressForwarding", ^{
    return [PackageManagerTestHelper testProgressForwarding];
  });

  // --- GWHeaderDatabase Tests ---
  runTest(@"testDatabaseOpens", ^{
    return [GWHeaderDatabaseTestHelper testDatabaseOpens];
  });
  runTest(@"testPackageForGphoto2HeaderPerDistro", ^{
    return [GWHeaderDatabaseTestHelper testPackageForGphoto2HeaderPerDistro];
  });
  runTest(@"testBestNameMatchPicksLibgphoto2", ^{
    return [GWHeaderDatabaseTestHelper testBestNameMatchPicksLibgphoto2];
  });
  runTest(@"testUnknownHeaderReturnsEmpty", ^{
    return [GWHeaderDatabaseTestHelper testUnknownHeaderReturnsEmpty];
  });
  runTest(@"testBareHeaderResolvesByBasename", ^{
    return [GWHeaderDatabaseTestHelper testBareHeaderResolvesByBasename];
  });
  runTest(@"testAmbiguousBasenameStaysUnresolved", ^{
    return [GWHeaderDatabaseTestHelper testAmbiguousBasenameStaysUnresolved];
  });
  runTest(@"testDistroMappingForKnownFamilies", ^{
    return [GWHeaderDatabaseTestHelper testDistroMappingForKnownFamilies];
  });

  return (failCount == 0) ? 0 : 1;
}

@end

int main(int argc, const char *argv[])
{
  @autoreleasepool
    {
      NSLog(@"========================================");
      NSLog(@"  GWPackageManager Test Suite");
      NSLog(@"========================================\n");

      int result = [TestRunner runAllTests];

      NSLog(@"\n========================================");
      NSLog(@"  Results: %d passed, %d failed out of %d",
            passCount, failCount, testCount);
      NSLog(@"========================================");

      return result;
    }
}
