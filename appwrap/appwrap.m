/*
 * appwrap - Create GNUstep application bundles from .desktop files
 * 
 * Usage: appwrap /path/to/application.desktop
 * 
 * This tool takes a freedesktop .desktop file and creates a GNUstep
 * application bundle that can be launched from the system.
 */

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Desktop file parser
@interface DesktopFileParser : NSObject
{
  NSMutableDictionary *entries;
}

- (id)initWithFile:(NSString *)path;
- (NSString *)stringForKey:(NSString *)key;
- (NSArray *)arrayForKey:(NSString *)key;
- (BOOL)parseFile:(NSString *)path;

@end

@implementation DesktopFileParser

- (id)init
{
  self = [super init];
  if (self)
    {
      entries = [[NSMutableDictionary alloc] init];
    }
  return self;
}

- (id)initWithFile:(NSString *)path
{
  self = [self init];
  if (self && ![self parseFile:path])
    {
      [self release];
      return nil;
    }
  return self;
}

- (BOOL)parseFile:(NSString *)path
{
  NSError *error = nil;
  NSString *content = [NSString stringWithContentsOfFile:path 
                                                  encoding:NSUTF8StringEncoding 
                                                     error:&error];
  if (!content)
    {
      NSLog(@"Error reading file: %@", [error localizedDescription]);
      return NO;
    }

  NSArray *lines = [content componentsSeparatedByString:@"\n"];
  NSString *currentSection = nil;

  for (NSString *line in lines)
    {
      // Skip empty lines and comments
      NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceCharacterSet]];
      if ([trimmed length] == 0 || [trimmed hasPrefix:@"#"])
        continue;

      // Handle sections
      if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"])
        {
          currentSection = [trimmed substringWithRange:NSMakeRange(1, [trimmed length] - 2)];
          continue;
        }

      // Skip lines that are not in Desktop Entry section
      if (![currentSection isEqualToString:@"Desktop Entry"])
        continue;

      // Parse key=value pairs
      NSArray *parts = [trimmed componentsSeparatedByString:@"="];
      if ([parts count] >= 2)
        {
          NSString *key = [[parts objectAtIndex:0] stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
          NSString *value = [[parts objectAtIndex:1] stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
          
          // Handle values with '=' in them
          if ([parts count] > 2)
            {
              NSMutableArray *valueParts = [NSMutableArray arrayWithArray:
                                            [parts subarrayWithRange:NSMakeRange(1, [parts count] - 1)]];
              value = [valueParts componentsJoinedByString:@"="];
              value = [value stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
            }

          [entries setObject:value forKey:key];
        }
    }

  return YES;
}

- (NSString *)stringForKey:(NSString *)key
{
  return [entries objectForKey:key];
}

- (NSArray *)arrayForKey:(NSString *)key
{
  NSString *value = [entries objectForKey:key];
  if (!value)
    return nil;
  
  // Handle semicolon-separated values (freedesktop standard)
  return [value componentsSeparatedByString:@";"];
}

- (void)dealloc
{
  [entries release];
  [super dealloc];
}

@end

// App bundle creator
@interface AppBundleCreator : NSObject

- (BOOL)createBundleFromDesktopFile:(NSString *)desktopPath
                           outputDir:(NSString *)outputDir;
- (BOOL)createBundleStructure:(NSString *)appPath
                  withAppName:(NSString *)appName;
- (BOOL)createInfoPlist:(NSString *)appPath
            desktopInfo:(DesktopFileParser *)parser
                appName:(NSString *)appName
              execPath:(NSString *)execPath
          iconFilename:(NSString *)iconFilename;
- (BOOL)createLauncherScript:(NSString *)appPath
                 execCommand:(NSString *)command
                 iconPath:(NSString *)iconPath
                 scriptName:(NSString *)scriptName;
- (NSString *)resolveIconPath:(NSString *)iconName;
- (NSString *)copyIconToBundle:(NSString *)iconPath
                      toBundleResources:(NSString *)resourcesPath
                      appName:(NSString *)appName;

// Sanitize freedesktop Exec field by removing field codes so the POSIX script
// contains a plain executable command without % codes.
- (NSString *)sanitizeExecCommand:(NSString *)command;

@end

@implementation AppBundleCreator

- (BOOL)createBundleFromDesktopFile:(NSString *)desktopPath
                           outputDir:(NSString *)outputDir
{
  // Parse the desktop file
  DesktopFileParser *parser = [[DesktopFileParser alloc] initWithFile:desktopPath];
  if (!parser)
    {
      NSLog(@"Failed to parse desktop file: %@", desktopPath);
      return NO;
    }

  // Get application metadata
  NSString *appName = [parser stringForKey:@"Name"];
  NSString *execCommand = [parser stringForKey:@"Exec"];
  NSString *iconName = [parser stringForKey:@"Icon"];

  if (!appName || !execCommand)
    {
      NSLog(@"Invalid desktop file: missing Name or Exec");
      [parser release];
      return NO;
    }

  // Use application name as bundle name (preserve whitespace)
  NSString *bundleName = appName;

  // Create the bundle path
  NSString *appPath = [NSString stringWithFormat:@"%@/%@.app", 
                       outputDir, bundleName];

  // Resolve icon path if provided
  NSString *resolvedIconPath = nil;
  if (iconName && [iconName length] > 0)
    {
      resolvedIconPath = [self resolveIconPath:iconName];
    }

  // Create bundle structure
  if (![self createBundleStructure:appPath withAppName:bundleName])
    {
      NSLog(@"Failed to create bundle structure");
      [parser release];
      return NO;
    }

  // Create the launcher script with the full Exec command; script name keeps spaces
  if (![self createLauncherScript:appPath 
                      execCommand:execCommand
                        iconPath:resolvedIconPath
                        scriptName:appName])
    {
      NSLog(@"Failed to create launcher script");
      [parser release];
      return NO;
    }

  // Copy icon if found and get the actual copied filename
  NSString *copiedIconFilename = nil;
  if (resolvedIconPath)
    {
      copiedIconFilename = [self copyIconToBundle:resolvedIconPath
                                  toBundleResources:[NSString stringWithFormat:@"%@/Resources", appPath]
                                           appName:bundleName];
    }

  // Create the Info.plist with the actual copied icon filename
  if (![self createInfoPlist:appPath 
                 desktopInfo:parser
                     appName:appName
                   execPath:execCommand
                   iconFilename:copiedIconFilename])
    {
      NSLog(@"Failed to create Info.plist");
      [parser release];
      return NO;
    }

  NSLog(@"Successfully created application bundle: %@", appPath);
  [parser release];
  return YES;
}

- (BOOL)createBundleStructure:(NSString *)appPath
                  withAppName:(NSString *)appName
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;

  // Create the .app directory
  if (![fm createDirectoryAtPath:appPath 
        withIntermediateDirectories:YES 
                         attributes:nil 
                              error:&error])
    {
      NSLog(@"Failed to create app directory: %@", [error localizedDescription]);
      return NO;
    }

  // Create Resources subdirectory
  NSString *resourcesPath = [NSString stringWithFormat:@"%@/Resources", appPath];
  if (![fm createDirectoryAtPath:resourcesPath 
        withIntermediateDirectories:YES 
                         attributes:nil 
                              error:&error])
    {
      NSLog(@"Failed to create Resources directory: %@", [error localizedDescription]);
      return NO;
    }

  return YES;
}

- (BOOL)createInfoPlist:(NSString *)appPath
            desktopInfo:(DesktopFileParser *)parser
                appName:(NSString *)appName
              execPath:(NSString *)execPath
          iconFilename:(NSString *)iconFilename
{
  NSMutableDictionary *infoPlist = [NSMutableDictionary dictionary];

  [infoPlist setObject:@"8.0" forKey:@"NSAppVersion"];
  [infoPlist setObject:appName forKey:@"NSExecutable"];
  [infoPlist setObject:appName forKey:@"NSApplicationName"];
  [infoPlist setObject:@"1.0" forKey:@"NSApplicationVersion"];
  [infoPlist setObject:appName forKey:@"CFBundleName"];

  // Try to get version from desktop file
  NSString *version = [parser stringForKey:@"Version"];
  if (version)
    {
      [infoPlist setObject:version forKey:@"NSApplicationVersion"];
    }

  // Set icon name if an icon was successfully copied
  if (iconFilename && [iconFilename length] > 0)
    {
      // Use the full filename with extension
      NSString *iconNameWithExtension = [iconFilename lastPathComponent];
      [infoPlist setObject:iconNameWithExtension forKey:@"NSIcon"];
    }

  // Create the plist file
  NSString *plistPath = [NSString stringWithFormat:@"%@/Resources/Info.plist", appPath];
  return [infoPlist writeToFile:plistPath atomically:YES];
}

- (BOOL)createLauncherScript:(NSString *)appPath
                 execCommand:(NSString *)command
                 iconPath:(NSString *)iconPath
                 scriptName:(NSString *)scriptName
{
  NSFileManager *fm = [NSFileManager defaultManager];
  // Use the provided scriptName (full appName with spaces) for the executable file
  NSString *launcherPath = [NSString stringWithFormat:@"%@/%@", appPath, scriptName];

  // Sanitize Exec= field codes (%U, %u, %F, %f, %i, %c, %k) and %% → %
  NSString *sanitized = [self sanitizeExecCommand:command];
  if (!sanitized || [sanitized length] == 0)
    {
      NSLog(@"Failed to sanitize Exec command");
      return NO;
    }

  // Create the launcher script using the sanitized command
  NSString *script = [NSString stringWithFormat:
    @"#!/bin/sh\n"
    @"# Auto-generated launcher script from desktop file Exec field\n"
    @"exec %@ \"$@\"\n",
    sanitized];

  NSError *error = nil;
  if (![script writeToFile:launcherPath 
                 atomically:YES 
                   encoding:NSUTF8StringEncoding 
                      error:&error])
    {
      NSLog(@"Failed to write launcher script: %@", [error localizedDescription]);
      return NO;
    }

  // Make the script executable
  [fm setAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0755]
                                                forKey:NSFilePosixPermissions]
        ofItemAtPath:launcherPath error:&error];

  return YES;
}

- (NSString *)sanitizeExecCommand:(NSString *)command
{
  if (!command) { return nil; }

  NSMutableString *mutable = [NSMutableString stringWithString:command];

  // Remove common freedesktop field codes
  NSArray *codes = @[@"%U", @"%u", @"%F", @"%f", @"%i", @"%c", @"%k"];
  for (NSString *code in codes)
    {
      [mutable replaceOccurrencesOfString:code
                               withString:@""
                                  options:0
                                    range:NSMakeRange(0, [mutable length])];
    }

  // %% represents a literal percent
  [mutable replaceOccurrencesOfString:@"%%"
                           withString:@"%"
                              options:0
                                range:NSMakeRange(0, [mutable length])];

  // Collapse whitespace that may result from removals
  NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  NSArray *parts = [mutable componentsSeparatedByCharactersInSet:ws];
  NSMutableArray *filtered = [NSMutableArray array];
  for (NSString *p in parts)
    {
      if ([p length] > 0) { [filtered addObject:p]; }
    }
  NSString *collapsed = [filtered componentsJoinedByString:@" "];
  return collapsed;
}

- (NSString *)resolveIconPath:(NSString *)iconName
{
  NSFileManager *fm = [NSFileManager defaultManager];
  
  // If it's already a full path and exists, use it
  if ([iconName hasPrefix:@"/"] && [fm fileExistsAtPath:iconName])
    {
      return iconName;
    }

  // Common icon search paths
  NSArray *searchPaths = @[
    @"/usr/share/icons/hicolor/256x256/apps",
    @"/usr/share/icons/hicolor/128x128/apps",
    @"/usr/share/icons/hicolor/96x96/apps",
    @"/usr/share/icons/hicolor/64x64/apps",
    @"/usr/share/icons/hicolor/48x48/apps",
    @"/usr/share/pixmaps",
    @"/usr/local/share/pixmaps"
  ];

  // Try various extensions
  NSArray *extensions = @[@".png", @".svg", @".xpm", @""];

  for (NSString *searchPath in searchPaths)
    {
      for (NSString *ext in extensions)
        {
          NSString *candidatePath = [NSString stringWithFormat:@"%@/%@%@",
                                    searchPath, iconName, ext];
          if ([fm fileExistsAtPath:candidatePath])
            {
              return candidatePath;
            }
        }
    }

  NSLog(@"Warning: Could not find icon file for: %@", iconName);
  return nil;
}

- (NSString *)copyIconToBundle:(NSString *)iconPath
                toBundleResources:(NSString *)resourcesPath
                       appName:(NSString *)appName
{
  if (!iconPath)
    return nil;

  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;

  // Check if the icon file exists and has non-zero size
  NSDictionary *fileAttrs = [fm attributesOfItemAtPath:iconPath error:&error];
  if (!fileAttrs)
    {
      NSLog(@"Warning: Could not read icon file attributes: %@", [error localizedDescription]);
      return nil;
    }

  unsigned long long fileSize = [fileAttrs fileSize];
  if (fileSize == 0)
    {
      NSLog(@"Warning: Icon file is empty (0 bytes): %@", iconPath);
      return nil;
    }

  // Get the icon file extension
  NSString *iconExt = [iconPath pathExtension];
  if ([iconExt length] == 0)
    {
      iconExt = @"png";
    }

  // Create the destination path with the extension
  NSString *bundleIconPath = [NSString stringWithFormat:@"%@/%@.%@",
                             resourcesPath, appName, iconExt];

  // Copy icon to bundle Resources
  if (![fm copyItemAtPath:iconPath toPath:bundleIconPath error:&error])
    {
      NSLog(@"Warning: Failed to copy icon: %@", [error localizedDescription]);
      return nil;
    }

  // Verify the copied file is not empty
  NSDictionary *copiedAttrs = [fm attributesOfItemAtPath:bundleIconPath error:&error];
  if (!copiedAttrs || [copiedAttrs fileSize] == 0)
    {
      NSLog(@"Warning: Copied icon file is empty, removing: %@", bundleIconPath);
      [fm removeItemAtPath:bundleIconPath error:NULL];
      return nil;
    }

  // Return the filename with extension
  return [bundleIconPath lastPathComponent];
}

@end

// Main entry point
int main(int argc, char *argv[])
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  if (argc < 2)
    {
      fprintf(stderr, "Usage: %s [OPTIONS] /path/to/application.desktop [output_dir]\n", argv[0]);
      fprintf(stderr, "  If output_dir is not specified:\n");
      fprintf(stderr, "    - ~/Applications is used for non-root users\n");
      fprintf(stderr, "    - /Local/Applications is used for root\n");
      fprintf(stderr, "\nOptions:\n");
      fprintf(stderr, "  -f, --force    Overwrite existing app bundle without asking\n");
      [pool release];
      exit(EXIT_FAILURE);
    }

  BOOL forceOverwrite = NO;
  int desktopFileArgIdx = 1;

  // Parse options
  for (int i = 1; i < argc; i++)
    {
      NSString *arg = [NSString stringWithUTF8String:argv[i]];
      if ([arg isEqualToString:@"-f"] || [arg isEqualToString:@"--force"])
        {
          forceOverwrite = YES;
          desktopFileArgIdx = i + 1;
        }
    }

  // Check if we have a desktop file argument
  if (desktopFileArgIdx >= argc)
    {
      fprintf(stderr, "Error: Desktop file path required\n");
      [pool release];
      exit(EXIT_FAILURE);
    }

  NSString *desktopFilePath = [NSString stringWithUTF8String:argv[desktopFileArgIdx]];
  NSString *outputDir = nil;

  // Get output directory
  if (desktopFileArgIdx + 1 < argc)
    {
      outputDir = [NSString stringWithUTF8String:argv[desktopFileArgIdx + 1]];
    }
  else
    {
      // Use conditional directory based on whether running as root
      if (geteuid() == 0)
        {
          outputDir = @"/Local/Applications";
        }
      else
        {
          outputDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
        }
    }

  // Expand ~ in paths
  desktopFilePath = [desktopFilePath stringByExpandingTildeInPath];
  outputDir = [outputDir stringByExpandingTildeInPath];

  // Create output directory if it doesn't exist
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *dirError = nil;
  if (![fm fileExistsAtPath:outputDir])
    {
      if (![fm createDirectoryAtPath:outputDir
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&dirError])
        {
          fprintf(stderr, "Error: Failed to create output directory: %s\n",
                  [[dirError localizedDescription] UTF8String]);
          [pool release];
          exit(EXIT_FAILURE);
        }
    }

  // Check if desktop file exists
  if (![fm fileExistsAtPath:desktopFilePath])
    {
      fprintf(stderr, "Error: Desktop file not found: %s\n", [desktopFilePath UTF8String]);
      [pool release];
      exit(EXIT_FAILURE);
    }

  // Parse the desktop file to get the app name
  DesktopFileParser *parser = [[DesktopFileParser alloc] initWithFile:desktopFilePath];
  if (!parser)
    {
      fprintf(stderr, "Error: Failed to parse desktop file\n");
      [pool release];
      exit(EXIT_FAILURE);
    }

  NSString *appName = [parser stringForKey:@"Name"];
  [parser release];

  if (!appName)
    {
      fprintf(stderr, "Error: Desktop file has no Name field\n");
      [pool release];
      exit(EXIT_FAILURE);
    }

  // Create bundle path (preserve whitespace in directory name)
  NSString *bundleName = appName;
  NSString *bundlePath = [NSString stringWithFormat:@"%@/%@.app", 
                         outputDir, bundleName];

  // Check if bundle already exists
  if ([fm fileExistsAtPath:bundlePath])
    {
      if (!forceOverwrite)
        {
          // Ask user for confirmation
          fprintf(stderr, "Warning: Application bundle already exists: %s\n", 
                  [bundlePath UTF8String]);
          fprintf(stderr, "Overwrite? (y/n) ");
          fflush(stderr);

          int response = getchar();
          if (response != 'y' && response != 'Y')
            {
              fprintf(stderr, "Cancelled.\n");
              [pool release];
              exit(EXIT_FAILURE);
            }
        }

      // Delete the existing bundle
      NSError *error = nil;
      if (![fm removeItemAtPath:bundlePath error:&error])
        {
          fprintf(stderr, "Error: Failed to remove existing bundle: %s\n",
                  [[error localizedDescription] UTF8String]);
          [pool release];
          exit(EXIT_FAILURE);
        }
    }

  // Create the bundle
  AppBundleCreator *creator = [[AppBundleCreator alloc] init];
  BOOL success = [creator createBundleFromDesktopFile:desktopFilePath
                                             outputDir:outputDir];
  [creator release];

  [pool release];
  exit(success ? EXIT_SUCCESS : EXIT_FAILURE);
}
