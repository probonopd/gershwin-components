/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "EfiVar.h"

#define VERSION "1.0.0"

static const char *knownValues[] = {
  "de:3       German  (de, pc105, de_DE)",
  "en_US:0    U.S. English",
  "fr:1       French",
  "it:4       Italian",
  "es:8       Spanish",
  "pt_BR:71   Brazilian (ABNT)",
  "sv:7       Swedish",
  "da:9       Danish",
  "fi:17      Finnish",
  "nb:12      Norwegian",
  "ja:16384   Japanese KANA",
  "ru:19456   Russian",
  NULL
};

static void
usage(const char *prog)
{
  fprintf(stderr, "Usage: %s [value]\n\n", prog);
  fprintf(stderr, "Read or set the Apple prev-lang:kbd EFI NVRAM variable.\n");
  fprintf(stderr, "This variable persists the keyboard layout across boot volumes.\n\n");
  fprintf(stderr, "Without arguments, prints the current value.\n");
  fprintf(stderr, "With a value (e.g., de:3), sets it.\n\n");
  fprintf(stderr, "Common values:\n");
  for (int i = 0; knownValues[i]; i++)
    fprintf(stderr, "  %s\n", knownValues[i]);
  fprintf(stderr, "\nFull mapping: https://github.com/helloSystem/hello/wiki/EFI-NVRAM\n");
}

static void
version(void)
{
  printf("efivar version " VERSION "\n");
  printf("Copyright (c) 2026 Simon Peter\n");
  printf("License BSD-2-Clause\n");
}

int
main(int argc, char *argv[], char *envp[])
{
  NSAutoreleasePool *pool;

#ifdef GS_PASS_ARGUMENTS
  GSInitializeProcess(argc, argv, envp);
#else
  (void)envp;
#endif
  pool = [NSAutoreleasePool new];

  EfiVar *efi = EfiVarCreate();
  if (!efi)
    {
      fprintf(stderr, "efivar: Unsupported platform\n");
      [pool release];
      return EXIT_FAILURE;
    }

  // Ensure EFI subsystem is available (load modules, mount fs, etc.)
  NSString *err = [efi ensureAvailable];
  if (err)
    {
      fprintf(stderr, "efivar: %s\n", [err UTF8String]);
      [pool release];
      return EXIT_FAILURE;
    }

  // Parse arguments
  if (argc >= 2)
    {
      if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)
        {
          usage(argv[0]);
          [pool release];
          return EXIT_SUCCESS;
        }
      if (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--version") == 0)
        {
          version();
          [pool release];
          return EXIT_SUCCESS;
        }

      // Validate value format (must contain a colon)
      const char *val = argv[1];
      if (!strchr(val, ':'))
        {
          fprintf(stderr, "efivar: Invalid value '%s' — expected format locale:number "
                          "(e.g., de:3)\n", val);
          [pool release];
          return EXIT_FAILURE;
        }

      // Write mode
      NSString *value = [NSString stringWithUTF8String:val];

      // Check current value first
      NSString *current = [efi readValue:EFI_VAR_PREV_LANG guid:EFI_GUID_KEYBOARD];
      if (current)
        {
          if ([current isEqualToString:value])
            {
              printf("%s already set to %s\n",
                     [EFI_VAR_PREV_LANG UTF8String], [value UTF8String]);
              [pool release];
              return EXIT_SUCCESS;
            }
        }

      if (![efi writeValue:value name:EFI_VAR_PREV_LANG guid:EFI_GUID_KEYBOARD])
        {
          NSString *lerr = [efi lastError];
          if (lerr)
            fprintf(stderr, "efivar: %s\n", [lerr UTF8String]);
          else
            fprintf(stderr, "efivar: Failed to write %s = %s\n",
                    [EFI_VAR_PREV_LANG UTF8String], [value UTF8String]);
          [pool release];
          return EXIT_FAILURE;
        }

      printf("%s = %s\n", [EFI_VAR_PREV_LANG UTF8String], [value UTF8String]);
      [pool release];
      return EXIT_SUCCESS;
    }

  // Read mode
  NSString *current = [efi readValue:EFI_VAR_PREV_LANG guid:EFI_GUID_KEYBOARD];
  if (!current)
    {
      NSString *lerr = [efi lastError];
      if (lerr)
        fprintf(stderr, "efivar: %s\n", [lerr UTF8String]);
      else
        fprintf(stderr, "efivar: %s not set\n", [EFI_VAR_PREV_LANG UTF8String]);
      [pool release];
      return EXIT_FAILURE;
    }

  printf("%s\n", [current UTF8String]);
  [pool release];
  return EXIT_SUCCESS;
}
