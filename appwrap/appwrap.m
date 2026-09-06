/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>

#import "GWBundleCreator.h"
#import "DesktopFileParser.h"
#import "GWUtils.h"

static void print_usage(const char *prog)
{
  fprintf(stderr, "Usage: %s [OPTIONS] /path/to/application.desktop [output_dir]\n", prog);
  fprintf(stderr, "       %s [OPTIONS] -c|--command \"command to run\" [-i|--icon /path/to/icon.png] [output_dir]\n", prog);
  fprintf(stderr, "\nOptions:\n");
  fprintf(stderr, "  -f, --force    Overwrite existing app bundle without asking\n");
  fprintf(stderr, "  -c, --command  Provide a command line to execute instead of a .desktop file (accepts args; use -- or quote your command)\n");
  fprintf(stderr, "  -i, --icon     Path to an icon file to use (overrides .desktop Icon resolution)\n");
  fprintf(stderr, "  -N, --name     Explicit application name to use for the bundle\n");
  fprintf(stderr, "  -a, --append-arg ARG   Append ARG to the command (may be used multiple times)\n");
  fprintf(stderr, "  -p, --prepend-arg ARG  Prepend ARG to the command (may be used multiple times)\n");
  fprintf(stderr, "  -h, --help     Show this help\n");
}

int main(int argc, char *argv[])
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  // Create a minimal NSApplication to allow AppKit operations (image loading, drawing)
  [[NSUserDefaults standardUserDefaults] setBool: YES forKey: @"NSApplicationSuppressPSN"];
  NSApplication *app __attribute__((unused)) = [NSApplication sharedApplication];

  BOOL forceOverwrite = NO;
  char *commandArg = NULL;
  char *iconArg = NULL;
  char *nameArg = NULL;

  // Support multiple prepend/append args
  NSMutableArray *prependArgs = [NSMutableArray array];
  NSMutableArray *appendArgs = [NSMutableArray array];

  static struct option long_options[] = {
    {"force", no_argument, 0, 'f'},
    {"command", required_argument, 0, 'c'},
    {"icon", required_argument, 0, 'i'},
    {"name", required_argument, 0, 'N'},
    {"append-arg", required_argument, 0, 'a'},
    {"prepend-arg", required_argument, 0, 'p'},
    {"help", no_argument, 0, 'h'},
    {0, 0, 0, 0}
  };

  int opt;
  int option_index = 0;
  while ((opt = getopt_long(argc, argv, "fc:i:hN:a:p:", long_options, &option_index)) != -1)
    {
      switch (opt)
        {
        case 'f':
          forceOverwrite = YES;
          break;
        case 'c':
          commandArg = optarg;
          break;
        case 'i':
          iconArg = optarg;
          break;
        case 'N':
          nameArg = optarg;
          break;
        case 'a':
          if (optarg) [appendArgs addObject:[NSString stringWithUTF8String:optarg]];
          break;
        case 'p':
          if (optarg) [prependArgs addObject:[NSString stringWithUTF8String:optarg]];
          break;
        case 'h':
          print_usage(argv[0]);
          [pool release];
          exit(EXIT_SUCCESS);
          break;
        default:
          print_usage(argv[0]);
          [pool release];
          exit(EXIT_FAILURE);
        }
    }

  BOOL commandMode = (commandArg != NULL);

  NSString *desktopFilePath = nil;
  NSString *outputDir = nil;
  NSString *iconPath = nil;
  NSString *commandStr = nil;

  // Positional arguments handling for desktop-mode or command-mode
  if (commandMode)
    {
      commandStr = [NSString stringWithUTF8String:commandArg];
      if (!commandStr || [commandStr length] == 0)
        {
          [GWUtils showErrorAlertWithTitle:@"Error" message:@"Empty --command value"];
          [pool release];
          exit(EXIT_FAILURE);
        }

      // Collect remaining positionals; these may be additional command args and/or an output_dir
      NSMutableArray *positionals = [NSMutableArray array];
      for (int i = optind; i < argc; i++)
        {
          [positionals addObject:[NSString stringWithUTF8String:argv[i]]];
        }

      // If the last positional appears path-like (contains '/','~', or starts with '/'), treat it as outputDir
      if ([positionals count] > 0)
        {
          NSString *last = [positionals lastObject];
          if ([last hasPrefix:@"/"] || [last hasPrefix:@"~"] || [last rangeOfString:@"/"].location != NSNotFound)
            {
              outputDir = last;
              [positionals removeLastObject];
            }
        }

      // Default output dir if none provided
      if (!outputDir)
        {
          if (geteuid() == 0)
            outputDir = @"/Local/Applications";
          else
            outputDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
        }

      // Append remaining positional tokens to the command (so --command can be used without quotes)
      for (NSString *p in positionals)
        {
          commandStr = [commandStr stringByAppendingFormat:@" %@", p];
        }

      // Prepend args, if any
      for (NSString *p in prependArgs)
        {
          commandStr = [NSString stringWithFormat:@"%@ %@", p, commandStr];
        }

      // Append args, if any
      for (NSString *p in appendArgs)
        {
          commandStr = [commandStr stringByAppendingFormat:@" %@", p];
        }

      if (iconArg)
        iconPath = [NSString stringWithUTF8String:iconArg];
    }
  else
    {
      if (optind >= argc)
        {
          fprintf(stderr, "Error: Desktop file path required\n");
          print_usage(argv[0]);
          [pool release];
          exit(EXIT_FAILURE);
        }

      desktopFilePath = [NSString stringWithUTF8String:argv[optind]];
      if (optind + 1 < argc)
        outputDir = [NSString stringWithUTF8String:argv[optind + 1]];
      else
        {
          if (geteuid() == 0)
            outputDir = @"/Local/Applications";
          else
            outputDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
        }
    }

  // Expand ~ in paths
  if (desktopFilePath) desktopFilePath = [desktopFilePath stringByExpandingTildeInPath];
  if (outputDir) outputDir = [outputDir stringByExpandingTildeInPath];
  if (iconPath) iconPath = [iconPath stringByExpandingTildeInPath];

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
          NSString *msg = [NSString stringWithFormat:@"Failed to create output directory: %@", [dirError localizedDescription]];
          [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
          [pool release];
          exit(EXIT_FAILURE);
        }
    }

  // In desktop mode, validate the desktop file exists
  if (!commandMode)
    {
      if (![fm fileExistsAtPath:desktopFilePath])
        {
          NSString *msg = [NSString stringWithFormat:@"Desktop file not found: %@", desktopFilePath];
          [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
          [pool release];
          exit(EXIT_FAILURE);
        }
    }

  // Create the bundle
  GWBundleCreator *creator = [[GWBundleCreator alloc] init];
  BOOL success = NO;

  if (commandMode)
    {
      // Derive an app name from the first token of the command if necessary
      NSString *firstToken = nil;
      NSScanner *sc = [NSScanner scannerWithString:commandStr];
      [sc scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&firstToken];
      if (!firstToken || [firstToken length] == 0)
        firstToken = commandStr;

      NSString *candidate = [[firstToken lastPathComponent] stringByDeletingPathExtension];

      // If user provided an explicit name via --name/-N, use that; otherwise use the derived candidate
      NSString *appNameToUse = nil;
      if (nameArg && strlen(nameArg) > 0)
        {
          appNameToUse = [NSString stringWithUTF8String:nameArg];
        }
      else
        {
          appNameToUse = candidate;
        }

      NSString *bundleName = [GWUtils sanitizeFileName:appNameToUse];

      // Check for existing bundle and ask/overwrite depending on force
      NSString *bundlePath = [NSString stringWithFormat:@"%@/%@.app", outputDir, bundleName];
      if ([fm fileExistsAtPath:bundlePath])
        {
          if (!forceOverwrite)
            {
              fprintf(stderr, "Warning: Application bundle already exists: %s\n", [bundlePath UTF8String]);
              fprintf(stderr, "Overwrite? (y/n) "); fflush(stderr);
              int response = getchar();
              if (response != 'y' && response != 'Y')
                {
                  fprintf(stderr, "Cancelled.\n");
                  [creator release];
                  [pool release];
                  exit(EXIT_FAILURE);
                }
            }

          NSError *remErr = nil;
          if (![fm removeItemAtPath:bundlePath error:&remErr])
            {
              NSString *msg = [NSString stringWithFormat:@"Failed to remove existing bundle: %@", [remErr localizedDescription]];
              [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
              [creator release];
              [pool release];
              exit(EXIT_FAILURE);
            }
        }

      success = [creator createBundleFromCommand:commandStr appName:appNameToUse iconPath:iconPath outputDir:outputDir];
    }
  else
    {
      // Desktop file mode - reuse existing flow
      DesktopFileParser *parser = [[DesktopFileParser alloc] initWithFile:desktopFilePath];
      if (!parser)
        {
          NSString *msg = [NSString stringWithFormat:@"Failed to parse desktop file: %@", desktopFilePath];
          [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
          [creator release];
          [pool release];
          exit(EXIT_FAILURE);
        }

      NSString *appName = [parser stringForKey:@"Name"];
      [parser release];

      if (!appName)
        {
          NSString *msg = @"Desktop file has no Name field";
          [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
          [creator release];
          [pool release];
          exit(EXIT_FAILURE);
        }

      NSString *bundleName = appName;
      NSString *bundlePath = [NSString stringWithFormat:@"%@/%@.app", outputDir, bundleName];

      if ([fm fileExistsAtPath:bundlePath])
        {
          if (!forceOverwrite)
            {
              fprintf(stderr, "Warning: Application bundle already exists: %s\n", [bundlePath UTF8String]);
              fprintf(stderr, "Overwrite? (y/n) "); fflush(stderr);
              int response = getchar();
              if (response != 'y' && response != 'Y')
                {
                  fprintf(stderr, "Cancelled.\n");
                  [creator release];
                  [pool release];
                  exit(EXIT_FAILURE);
                }
            }

          NSError *remErr = nil;
          if (![fm removeItemAtPath:bundlePath error:&remErr])
            {
              NSString *msg = [NSString stringWithFormat:@"Failed to remove existing bundle: %@", [remErr localizedDescription]];
              [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
              [creator release];
              [pool release];
              exit(EXIT_FAILURE);
            }
        }

      success = [creator createBundleFromDesktopFile:desktopFilePath outputDir:outputDir];
    }

  [creator release];

  if (success)
    {
      NSTask *ms = [[NSTask alloc] init];
      [ms setLaunchPath:@"/usr/bin/env"];
      [ms setArguments:@[@"make_services"]];
      [ms launch];
      [ms waitUntilExit];
      [ms release];
    }

  [pool release];
  exit(success ? EXIT_SUCCESS : EXIT_FAILURE);
}
