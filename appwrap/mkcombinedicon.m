/*
 * Copyright (c) 2026 Simon Peter
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

#import "GWDocumentIcon.h"

static void print_usage(const char *prog)
{
  fprintf(stderr, "Usage: %s [OPTIONS] /path/to/Application.bundle extension [output.png]\n", prog);
  fprintf(stderr, "\nOptions:\n");
  fprintf(stderr, "  --size N     Icon size in pixels (default: 256)\n");
  fprintf(stderr, "  -h, --help   Show this help\n");
}

int main(int argc, char *argv[])
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NSApplicationSuppressPSN"];
  NSApplication *app __attribute__((unused)) = [NSApplication sharedApplication];

  int iconSize = 256;

  static struct option long_options[] = {
    {"size", required_argument, 0, 's'},
    {"help", no_argument, 0, 'h'},
    {0, 0, 0, 0}
  };

  int opt;
  int option_index = 0;
  while ((opt = getopt_long(argc, argv, "s:h", long_options, &option_index)) != -1)
    {
      switch (opt)
        {
        case 's':
          iconSize = atoi(optarg);
          if (iconSize <= 0) iconSize = 256;
          break;
        case 'h':
          print_usage(argv[0]);
          [pool release];
          exit(EXIT_SUCCESS);
        default:
          print_usage(argv[0]);
          [pool release];
          exit(EXIT_FAILURE);
        }
    }

  if (optind >= argc || optind + 1 >= argc)
    {
      fprintf(stderr, "Error: Bundle path and extension required\n");
      print_usage(argv[0]);
      [pool release];
      exit(EXIT_FAILURE);
    }

  NSString *bundlePath = [NSString stringWithUTF8String:argv[optind]];
  NSString *extensionText = [NSString stringWithUTF8String:argv[optind + 1]];
  NSString *outputPath = nil;

  if (optind + 2 < argc)
    {
      outputPath = [NSString stringWithUTF8String:argv[optind + 2]];
    }

  bundlePath = [bundlePath stringByExpandingTildeInPath];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:bundlePath])
    {
      fprintf(stderr, "Error: Bundle not found: %s\n", [bundlePath UTF8String]);
      [pool release];
      exit(EXIT_FAILURE);
    }

  NSImage *appIcon = [[NSWorkspace sharedWorkspace] iconForFile:bundlePath];
  [appIcon retain];

  NSData *pngData = [GWDocumentIcon createCombinedIconPNGWithAppIcon:appIcon
                                                      extensionText:extensionText
                                                               size:iconSize];
  [appIcon release];

  if (!pngData)
    {
      fprintf(stderr, "Error: Failed to create combined icon\n");
      [pool release];
      exit(EXIT_FAILURE);
    }

  if (!outputPath)
    {
      NSString *bundleName = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
      outputPath = [NSString stringWithFormat:@"%@-%@.png", bundleName, extensionText];
    }

  if (![pngData writeToFile:outputPath atomically:YES])
    {
      fprintf(stderr, "Error: Failed to write icon to %s\n", [outputPath UTF8String]);
      [pool release];
      exit(EXIT_FAILURE);
    }

  printf("Combined icon created: %s\n", [outputPath UTF8String]);

  [pool release];
  return EXIT_SUCCESS;
}
