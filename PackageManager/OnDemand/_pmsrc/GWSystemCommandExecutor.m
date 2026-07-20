/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWSystemCommandExecutor - NSTask-based implementation of the
 * GWSystemCommandExecutor protocol. Runs system commands and captures
 * their output.
 */

#import "GWSystemCommandExecutor.h"

@implementation GWSystemCommandExecutor

static GWSystemCommandExecutor *sharedExecutor = nil;

+ (GWSystemCommandExecutor *)sharedExecutor
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedExecutor = [[self alloc] init];
  });
  return sharedExecutor;
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
  NSLog(@"GWSystemCommandExecutor -> execute: %@ %@", path, [args componentsJoinedByString:@" "]);

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:path];
  [task setArguments:args];

  NSPipe *outPipe = [NSPipe pipe];
  NSPipe *errPipe = [NSPipe pipe];
  [task setStandardOutput:outPipe];
  [task setStandardError:errPipe];

  @try
    {
      [task launch];
      [task waitUntilExit];

      int status = [task terminationStatus];

      if (output)
        {
          NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
          *output = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
          if (!*output) *output = @"";
        }

      if (errorOutput)
        {
          NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
          *errorOutput = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
          if (!*errorOutput) *errorOutput = @"";
        }

      NSLog(@"GWSystemCommandExecutor <- exit code %d (output length: %lu chars)", status, (unsigned long)[*output length]);
      return status;
    }
  @catch (NSException *e)
    {
      NSLog(@"GWSystemCommandExecutor [FAIL] exception executing %@: %@", path, e);
      if (output) *output = @"";
      if (errorOutput) *errorOutput = [NSString stringWithFormat:@"%@", e];
      return -1;
    }
}

- (int)execute:(NSString *)path
     arguments:(NSArray *)args
 stderrCallback:(void (^)(NSString *line))callback
 capturedErrorOutput:(NSString *__autoreleasing *)errorOutput
{
  return [self execute:path arguments:args
        stdoutCallback:nil
        stderrCallback:callback
  capturedErrorOutput:errorOutput];
}

static dispatch_source_t _streamPipe(int fd,
                                      NSMutableString *lineBuf,
                                      NSMutableString *captured,
                                      void (^callback)(NSString *line),
                                      dispatch_semaphore_t eofSem)
{
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0,
    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));

  dispatch_source_set_event_handler(source, ^{
    char buffer[4096];
    ssize_t n = read(fd, buffer, sizeof(buffer));
    if (n > 0)
      {
        NSString *chunk = [[NSString alloc] initWithBytes:buffer length:n
                                                encoding:NSUTF8StringEncoding];
        if (chunk)
          {
            if (captured)
              {
                @synchronized(captured)
                  {
                    [captured appendString:chunk];
                  }
              }

            [lineBuf appendString:chunk];
            NSRange r;
            while ((r = [lineBuf rangeOfString:@"\n"]).location != NSNotFound)
              {
                NSString *line = [lineBuf substringToIndex:r.location];
                [lineBuf deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
                line = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@"\r"]];
                if (callback)
                  callback(line);
              }
          }
      }
    else
      {
        dispatch_source_cancel(source);
      }
  });

  dispatch_source_set_cancel_handler(source, ^{
    if (eofSem)
      dispatch_semaphore_signal(eofSem);
  });

  dispatch_resume(source);
  return source;
}

- (int)execute:(NSString *)path
     arguments:(NSArray *)args
 stdoutCallback:(void (^)(NSString *line))stdoutCallback
 stderrCallback:(void (^)(NSString *line))stderrCallback
 capturedErrorOutput:(NSString *__autoreleasing *)errorOutput
{
  NSLog(@"GWSystemCommandExecutor -> execute (live both): %@ %@", path, [args componentsJoinedByString:@" "]);

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:path];
  [task setArguments:args];

  NSPipe *outPipe = [NSPipe pipe];
  [task setStandardOutput:outPipe];
  NSFileHandle *outHandle = [outPipe fileHandleForReading];

  NSPipe *errPipe = [NSPipe pipe];
  [task setStandardError:errPipe];
  NSFileHandle *errHandle = [errPipe fileHandleForReading];

  NSMutableString *captured = [NSMutableString string];
  NSMutableString *outBuf = [NSMutableString string];
  NSMutableString *errBuf = [NSMutableString string];

  dispatch_semaphore_t outSem = dispatch_semaphore_create(0);
  dispatch_semaphore_t errSem = dispatch_semaphore_create(0);
  __block dispatch_source_t outSource = nil;
  __block dispatch_source_t errSource = nil;

  outSource = _streamPipe([outHandle fileDescriptor], outBuf, nil,
                          stdoutCallback, outSem);
  errSource = _streamPipe([errHandle fileDescriptor], errBuf, captured,
                          stderrCallback, errSem);

  @try
    {
      [task launch];
      dispatch_semaphore_wait(outSem, DISPATCH_TIME_FOREVER);
      dispatch_semaphore_wait(errSem, DISPATCH_TIME_FOREVER);
      [task waitUntilExit];
    }
  @catch (NSException *e)
    {
      NSLog(@"GWSystemCommandExecutor [FAIL] exception executing %@: %@", path, e);
      if (outSource) dispatch_source_cancel(outSource);
      if (errSource) dispatch_source_cancel(errSource);
      if (errorOutput) *errorOutput = [captured copy];
      return -1;
    }

  // Flush partial final lines
  if ([outBuf length] > 0 && stdoutCallback)
    stdoutCallback([outBuf copy]);
  if ([errBuf length] > 0 && stderrCallback)
    stderrCallback([errBuf copy]);

  int status = [task terminationStatus];
  if (errorOutput)
    {
      @synchronized(captured)
        {
          *errorOutput = [captured copy];
        }
    }

  NSLog(@"GWSystemCommandExecutor <- exit code %d (stderr: %lu chars)", status, (unsigned long)[captured length]);
  return status;
}

@end
