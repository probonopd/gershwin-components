/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import <string.h>

#import "DUApplicationDelegate.h"
#import "DUBackendFactory.h"
#import "DUOperationManager.h"
#import "DUPreferencesController.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"

// Headless tree dump for smoke tests and scripting (ARCHITECTURE.md 78):
// prints the discovered hierarchy without touching the GUI.
static int RunListMode(void)
{
    [DUPreferencesController registerDefaults];
    NSError *error = nil;
    id backend = [DUBackendFactory backendWithError:&error];
    if (backend == nil) {
        printf("error: no backend available\n");
        return 1;
    }
    DUOperationManager *operations = [[DUOperationManager alloc] init];
    DUStorageManager *manager =
        [[DUStorageManager alloc] initWithBackend:backend
                                  operationManager:operations];
    if (![manager refreshWithError:&error]) {
        printf("error: discovery failed\n");
        return 1;
    }

    // Iterative pre-order dump; a recursive block would self-retain under
    // ARC and warn about it.
    NSMutableArray<NSArray<id> *> *work = [NSMutableArray array];
    for (DUStorageObject *root in manager.currentObjects) {
        [work addObject:@[ root, @0 ]];
    }
    while (work.count > 0) {
        NSArray<id> *entry = work.lastObject;
        [work removeLastObject];
        DUStorageObject *object = entry[0];
        NSInteger depth = [entry[1] integerValue];
        printf("%*s%s [%s] type=%ld path=%s\n",
               (int)(depth * 2), "",
               object.displayName.UTF8String ?: "(unnamed)",
               object.identifier.UTF8String,
               (long)object.type,
               object.backendPath.UTF8String ?: "-");
        for (DUStorageObject *child in object.children) {
            [work addObject:@[ child, @(depth + 1) ]];
        }
    }
    return 0;
}

// Single-refresh smoke mode mirroring the Processes tool pattern.
static int RunTestRefreshMode(void)
{
    [DUPreferencesController registerDefaults];
    NSError *error = nil;
    id backend = [DUBackendFactory backendWithError:&error];
    DUOperationManager *operations = [[DUOperationManager alloc] init];
    DUStorageManager *manager =
        [[DUStorageManager alloc] initWithBackend:backend
                                  operationManager:operations];

    NSThread *worker = [[NSThread alloc]
        initWithBlock:^{
            @autoreleasepool {
                [manager refreshWithError:NULL];
            }
        }];
    [worker start];

    // Bounded wait so a hung backend cannot wedge CI.
    int waited = 0;
    while (!worker.isFinished && waited < 10) {
        sleep(1);
        waited++;
    }
    NSUInteger count = manager.currentObjects.count;
    printf("refresh finished. roots=%lu\n", (unsigned long)count);
    return count > 0 ? 0 : 1;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        // Ensure GNUstep environment when launched outside a login shell.
        if (getenv("GNUSTEP_SYSTEM_ROOT") == NULL) {
            setenv("GNUSTEP_SYSTEM_ROOT", "/System", 1);
        }
        if (getenv("GNUSTEP_SYSTEM_LIBRARY") == NULL) {
            setenv("GNUSTEP_SYSTEM_LIBRARY", "/System/Library", 1);
        }
        const char *ld = getenv("LD_LIBRARY_PATH");
        if (!ld || strstr(ld, "/System/Library/Libraries") == NULL) {
            NSMutableString *newLd =
                [NSMutableString stringWithString:@"/System/Library/Libraries"];
            if (ld && strlen(ld) > 0) {
                [newLd appendFormat:@":%s", ld];
            }
            setenv("LD_LIBRARY_PATH", newLd.UTF8String, 1);
        }

        // First pass applies modifier flags regardless of position; the
        // second pass dispatches on the mode switch.
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--mock") == 0) {
                [[NSUserDefaults standardUserDefaults]
                    setBool:YES forKey:@"DUForceMockBackend"];
            }
        }
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--list") == 0) {
                return RunListMode();
            }
            if (strcmp(argv[i], "--test-refresh") == 0) {
                return RunTestRefreshMode();
            }
        }

        [NSApplication sharedApplication];
        // The desktop shell labels running apps by process name; keep it
        // in step with the human-readable application name.
        [[NSProcessInfo processInfo] setProcessName:@"Disk Utility"];
        DUApplicationDelegate *delegate = [[DUApplicationDelegate alloc] init];
        [NSApp setDelegate:delegate];
        [NSApp run];
    }
    return 0;
}
