/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "MGTypes.h"
#import "MGArchiverReader.h"
#import "MGArchiverWriter.h"
#import "MGTextWriter.h"
#import "MGTextReader.h"
#import "MGCompiler.h"

static void usage(void)
{
  fprintf(stderr, "Usage: make_gorm <command> [options]\n\n");
  fprintf(stderr, "Commands:\n");
  fprintf(stderr, "  decompile <input.gorm> <output.gormt>\n");
  fprintf(stderr, "    Convert binary .gorm to text representation\n\n");
  fprintf(stderr, "  compile <input.gormt> <output.gorm>\n");
  fprintf(stderr, "    Convert text representation to binary .gorm\n\n");
  fprintf(stderr, "  verify <input.gorm>\n");
  fprintf(stderr, "    Verify .gorm file can be read\n\n");
  fprintf(stderr, "  canonicalize <input.gormt>\n");
  fprintf(stderr, "    Normalize text representation\n\n");
}

static void collectObjects(id root, NSMutableArray *array)
{
  if (!root || [array containsObject:root]) return;
  [array addObject:root];

  if ([root isKindOfClass:[NSArray class]]) {
    for (id obj in (NSArray *)root)
      collectObjects(obj, array);
  } else if ([root isKindOfClass:[NSDictionary class]]) {
    for (id key in [(NSDictionary *)root allKeys]) {
      collectObjects([(NSDictionary *)root objectForKey:key], array);
      collectObjects(key, array);
    }
  } else if ([root isKindOfClass:[NSSet class]]) {
    for (id obj in (NSSet *)root)
      collectObjects(obj, array);
  }

  unsigned count = 0;
  Ivar *ivars = class_copyIvarList([root class], &count);
  for (unsigned i = 0; i < count; i++) {
    const char *type = ivar_getTypeEncoding(ivars[i]);
    if (type && *type == _C_ID) {
      id val = object_getIvar(root, ivars[i]);
      if (val && val != root)
        collectObjects(val, array);
    }
  }
  free(ivars);
}

static int cmd_decompile(int argc, char *argv[])
{
  if (argc < 4) {
    fprintf(stderr, "Usage: make_gorm decompile <input.gorm> <output.gormt>\n");
    return 1;
  }

  NSString *inputPath = [NSString stringWithUTF8String:argv[2]];
  NSString *outputPath = [NSString stringWithUTF8String:argv[3]];
  NSError *error = nil;

  NSString *dataPath = inputPath;
  BOOL isDir = NO;
  if ([[NSFileManager defaultManager] fileExistsAtPath:inputPath
                                           isDirectory:&isDir] && isDir) {
    dataPath = [inputPath stringByAppendingPathComponent:@"objects.gorm"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
      fprintf(stderr, "error: no objects.gorm in %s\n", argv[2]);
      return 1;
    }
  }

  NSData *data = [NSData dataWithContentsOfFile:dataPath options:0 error:&error];
  if (!data) {
    fprintf(stderr, "error: %s\n", [[error localizedDescription] UTF8String]);
    return 1;
  }

  MGArchiverReader *reader = [[MGArchiverReader alloc] init];
  MGArchive *archive = [reader parseArchiveFromData:data error:&error];
  RELEASE(reader);
  if (!archive) {
    fprintf(stderr, "error: %s\n", [[error localizedDescription] UTF8String]);
    return 1;
  }

#ifdef RECORDING_CODER
  @try {
    [NSApplication sharedApplication];
    NSUnarchiver *unarchiver = [[NSUnarchiver alloc]
      initForReadingWithData:data];
    id root = [unarchiver decodeObject];
    RELEASE(unarchiver);

    if (root) {
      NSMutableArray *allObjects = [NSMutableArray array];
      collectObjects(root, allObjects);

      for (MGArchiveObject *obj in archive.objects) {
        int32_t idx = obj.objectId - 1;
        if (idx >= 0 && (NSUInteger)idx < [allObjects count])
          obj.decodedObject = [allObjects objectAtIndex:idx];
      }
    }
  }
  @catch (NSException *e) {
    fprintf(stderr, "warning: NSUnarchiver: %s\n", [[e reason] UTF8String]);
  }
#endif

  @try {
    if (![MGTextWriter writeArchive:archive toPath:outputPath error:&error]) {
      fprintf(stderr, "error: %s\n", [[error localizedDescription] UTF8String]);
      return 1;
    }
  } @catch (NSException *e) {
    fprintf(stderr, "exception in writer: %s\n", [[e reason] UTF8String]);
    return 1;
  }

  return 0;
}

static int cmd_compile(int argc, char *argv[])
{
  if (argc < 4) {
    fprintf(stderr, "Usage: make_gorm compile <input.gormt> <output.gorm>\n");
    return 1;
  }

  NSString *inputPath = [NSString stringWithUTF8String:argv[2]];
  NSString *outputPath = [NSString stringWithUTF8String:argv[3]];
  NSError *error = nil;

  MGArchive *archive = [MGTextReader archiveFromPath:inputPath error:&error];
  if (!archive) {
    fprintf(stderr, "error: %s\n", [[error localizedDescription] UTF8String]);
    return 1;
  }

  MGCompiler *compiler = [[MGCompiler alloc] init];
  NSData *binary = [compiler compileArchive:archive error:&error];
  RELEASE(compiler);
  if (!binary) {
    fprintf(stderr, "error: %s\n", [[error localizedDescription] UTF8String]);
    return 1;
  }

  if ([outputPath hasSuffix:@".gorm"]) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:outputPath
  withIntermediateDirectories:YES attributes:nil error:NULL];

    NSString *objPath = [outputPath stringByAppendingPathComponent:@"objects.gorm"];
    [binary writeToFile:objPath atomically:YES];

    NSData *empty = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    [empty writeToFile:[outputPath stringByAppendingPathComponent:@"data.classes"]
            atomically:YES];
    [empty writeToFile:[outputPath stringByAppendingPathComponent:@"data.info"]
            atomically:YES];
  } else {
    [binary writeToFile:outputPath atomically:YES];
  }

  return 0;
}

static int cmd_verify(int argc, char *argv[])
{
  if (argc < 3) {
    fprintf(stderr, "Usage: make_gorm verify <input.gorm>\n");
    return 1;
  }

  NSString *inputPath = [NSString stringWithUTF8String:argv[2]];
  NSError *error = nil;

  NSString *dataPath = inputPath;
  BOOL isDir = NO;
  if ([[NSFileManager defaultManager] fileExistsAtPath:inputPath
                                           isDirectory:&isDir] && isDir)
    dataPath = [inputPath stringByAppendingPathComponent:@"objects.gorm"];

  NSData *data = [NSData dataWithContentsOfFile:dataPath options:0 error:&error];
  if (!data) {
    fprintf(stderr, "error: %s\n", [[error localizedDescription] UTF8String]);
    return 1;
  }

  MGArchiverReader *reader = [[MGArchiverReader alloc] init];
  MGArchive *archive = [reader parseArchiveFromData:data error:&error];
  RELEASE(reader);
  if (!archive) {
    fprintf(stderr, "error: %s\n", [[error localizedDescription] UTF8String]);
    return 1;
  }

  printf("OK: %u objects, %u classes, version %u\n",
         archive.objectCount, archive.classCount, archive.systemVersion);
  return 0;
}

static int cmd_canonicalize(int argc, char *argv[])
{
  if (argc < 3) {
    fprintf(stderr, "Usage: make_gorm canonicalize <input.gormt>\n");
    return 1;
  }

  NSString *inputPath = [NSString stringWithUTF8String:argv[2]];
  NSError *error = nil;

  MGArchive *archive = [MGTextReader archiveFromPath:inputPath error:&error];
  if (!archive) {
    fprintf(stderr, "error: %s\n", [[error localizedDescription] UTF8String]);
    return 1;
  }

  if (![MGTextWriter writeArchive:archive toPath:inputPath error:&error]) {
    fprintf(stderr, "error: %s\n", [[error localizedDescription] UTF8String]);
    return 1;
  }

  return 0;
}

int main(int argc, char *argv[])
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  if (argc < 2) {
    usage();
    [pool drain];
    return 1;
  }

  NSString *cmd = [NSString stringWithUTF8String:argv[1]];
  int result = 1;

       if ([cmd isEqualToString:@"decompile"])    result = cmd_decompile(argc, argv);
  else if ([cmd isEqualToString:@"compile"])      result = cmd_compile(argc, argv);
  else if ([cmd isEqualToString:@"verify"])       result = cmd_verify(argc, argv);
  else if ([cmd isEqualToString:@"canonicalize"]) result = cmd_canonicalize(argc, argv);
  else if ([cmd isEqualToString:@"--help"] || [cmd isEqualToString:@"-h"]) {
    usage(); result = 0;
  } else {
    fprintf(stderr, "Unknown command: %s\n\n", argv[1]);
    usage();
  }

  [pool drain];
  return result;
}
