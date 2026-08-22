/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WhisperController.h"
#import "AppearanceMetrics.h"
#import "WAudioLoader.h"
#import "WCapture.h"
#import "ALSABackend.h"
#import "OSSBackend.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSButton.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSProgressIndicator.h>
#import <AppKit/NSOpenPanel.h>
#import <AppKit/NSSavePanel.h>
#import <AppKit/NSPopUpButton.h>
#import <AppKit/NSStepper.h>
#import <AppKit/NSAlert.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSThread.h>
#import <objc/runtime.h>
#import <Foundation/NSTimer.h>
#import <Foundation/NSTask.h>
#import <Foundation/NSUserDefaults.h>
#import <Foundation/NSFileHandle.h>

#import "WhisperDlopen.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <strings.h>
#include <curl/curl.h>

// ── xdotool path (resolved once from PATH at first use) ────────────
static NSString *xdoPath = nil;

// ── Build progress (shared between build thread and main-thread timer) ─
static volatile int buildProgressPct = 0;
static volatile BOOL buildThreadRunning = NO;

// ── DockService protocol (forward decl — no link dependency) ────────
@protocol DockService <NSObject>
- (void)setProgressValue:(double)value;
- (void)setProgressVisible:(BOOL)visible;
- (void)clearAll;
@end

// ── Floating window: always on top, no keyboard input ──────────────
@interface WhisperFloatingWindow : NSWindow
@end
@implementation WhisperFloatingWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end



#define DEFAULT_WINDOW_WIDTH  480.0
#define DEFAULT_WINDOW_HEIGHT 347.0
#define CONTENT_MIN_WIDTH     413.0
#define CONTENT_MIN_HEIGHT    267.0

#define WHISPER_SAMPLE_RATE 16000

static NSString *kWhisperModelDir = @"Whisper/Models";

static const char *modelNames[] = {
    "ggml-tiny.en.bin",
    "ggml-tiny.bin",
    "ggml-base.en.bin",
    "ggml-base.bin",
    "ggml-small.en.bin",
    "ggml-small.bin",
    "ggml-medium.en.bin",
    "ggml-medium.bin",
    "ggml-large-v3.bin",
    "ggml-large-v3-turbo.bin",
    NULL
};

static const char *modelSizes[] = {
    "tiny.en (74 MB)",
    "tiny (74 MB)",
    "base.en (141 MB)",
    "base (141 MB)",
    "small.en (465 MB)",
    "small (465 MB)",
    "medium.en (1.42 GB)",
    "medium (1.42 GB)",
    "large-v3 (2.87 GB)",
    "large-v3-turbo (809 MB)",
    NULL
};

static const char *langCodes[] = {
    "auto", "en", "zh", "de", "es", "fr", "it", "pt", "nl", "ja",
    "ko", "ru", "ar", "tr", "pl", "uk", "ro", "hu", "sv", "da",
    "fi", "el", "cs", "sk", "bg", "hr", "sr", "lt", "lv", "et",
    "hi", "th", "vi", "id", "ms", "tl", "bn", "ta", "te", "mr",
    NULL
};

static const char *langNames[] = {
    "Auto-detect", "English", "Chinese", "German", "Spanish", "French",
    "Italian", "Portuguese", "Dutch", "Japanese", "Korean", "Russian",
    "Arabic", "Turkish", "Polish", "Ukrainian", "Romanian", "Hungarian",
    "Swedish", "Danish", "Finnish", "Greek", "Czech", "Slovak", "Bulgarian",
    "Croatian", "Serbian", "Lithuanian", "Latvian", "Estonian", "Hindi",
    "Thai", "Vietnamese", "Indonesian", "Malay", "Filipino", "Bengali",
    "Tamil", "Telugu", "Marathi",
    NULL
};

// C callback for progress
static void whisper_progress_cb(struct whisper_context *ctx,
                                struct whisper_state *state,
                                int progress, void *user_data)
{
    WhisperController *ctrl = (WhisperController *)user_data;
    [ctrl performSelectorOnMainThread:@selector(transcriptionProgress:)
                           withObject:[NSNumber numberWithInt:progress]
                        waitUntilDone:NO];
}

// C callback for new segments (fires during whisper_full decoding)
static void whisper_new_segment_cb(struct whisper_context *ctx,
                                   struct whisper_state *state,
                                   int n_new, void *user_data)
{
    WhisperController *ctrl = (WhisperController *)user_data;
    int total = wdlopen_full_n_segments(ctx);

    NSMutableArray *newSegs = [NSMutableArray array];
    NSMutableString *text = [NSMutableString string];

    for (int i = total - n_new; i < total; i++) {
        const char *seg_text = wdlopen_full_get_segment_text(ctx, i);
        if (!seg_text) continue;

        int64_t t0 = wdlopen_full_get_segment_t0(ctx, i);
        int64_t t1 = wdlopen_full_get_segment_t1(ctx, i);

        NSString *st = [NSString stringWithUTF8String:seg_text];
        if (!st) continue;

        NSDictionary *seg = [NSDictionary dictionaryWithObjectsAndKeys:
            st, @"text",
            [NSNumber numberWithLongLong:t0], @"t0",
            [NSNumber numberWithLongLong:t1], @"t1",
            nil];
        [newSegs addObject:seg];
        [text appendFormat:@"[%@ --> %@] %@\n",
            [ctrl formatTimestamp:t0],
            [ctrl formatTimestamp:t1],
            st];

        // Also stream to console
        fprintf(stdout, "Recognized: [%s --> %s] %s\n",
                [[ctrl formatTimestamp:t0] UTF8String],
                [[ctrl formatTimestamp:t1] UTF8String],
                seg_text);
        fflush(stdout);
    }

    if ([newSegs count] > 0) {
        NSDictionary *result = [NSDictionary dictionaryWithObjectsAndKeys:
            newSegs, @"segments",
            text, @"text",
            [NSNumber numberWithInt:total], @"total",
            nil];
        [ctrl performSelectorOnMainThread:@selector(appendStreamingResult:)
                               withObject:result
                            waitUntilDone:NO];
    }
}

@interface WhisperController ()
- (void)loadModel:(NSString *)modelPath;
- (void)unloadModel;
- (NSString *)modelDirPath;
@end

@implementation WhisperController

@synthesize mainWindow, availableModels, segments, currentFilePath;

- (NSString *)findTool:(NSString *)name
{
    NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    if (!pathEnv) return nil;
    NSArray *dirs = [pathEnv componentsSeparatedByString:@":"];
    for (NSString *dir in dirs) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:full])
            return full;
    }
    return nil;
}

- (void)playSubmarineSound
{
    NSString *path = @"/System/Library/Sounds/Submarine.wav";
    NSString *aplayer = [self findTool:@"aplay"];
    NSString *audioplayer = [self findTool:@"audioplay"];
    NSString *paplayer = [self findTool:@"paplay"];

    NSMutableDictionary *cEnv = [[[[NSProcessInfo processInfo] environment] mutableCopy] autorelease];
    [cEnv setObject:@"C" forKey:@"LC_ALL"];

    // Try each player: aplay, audioplay, paplay
    NSString *players[3] = { aplayer, audioplayer, paplayer };
    NSArray *args[3] = {
        @[@"-q", path],
        @[path],
        @[path]
    };
    for (int i = 0; i < 3; i++) {
        if (!players[i]) continue;
        NSLog(@"playSubmarineSound: trying %@", players[i]);
        NSTask *t = [[NSTask alloc] init];
        [t setLaunchPath:players[i]];
        [t setArguments:args[i]];
        [t setEnvironment:cEnv];
        @try {
            [t launch];
            [t waitUntilExit];
            if ([t terminationStatus] == 0) {
                NSLog(@"playSubmarineSound: succeeded with %@", players[i]);
                [t release];
                return;
            }
            NSLog(@"playSubmarineSound: %@ failed status=%d",
                  players[i], [t terminationStatus]);
        } @catch (NSException *e) {
            NSLog(@"playSubmarineSound: %@ threw %@", players[i], e);
        }
        [t release];
    }
    // Last resort: raw OSS — cat WAV to /dev/dsp
    NSLog(@"playSubmarineSound: trying cat > /dev/dsp");
    NSTask *t = [[NSTask alloc] init];
    [t setLaunchPath:@"/bin/sh"];
    [t setArguments:@[@"-c", [NSString stringWithFormat:@"cat '%@' > /dev/dsp 2>/dev/null", path]]];
    [t setEnvironment:cEnv];
    @try {
        [t launch];
        [t waitUntilExit];
        NSLog(@"playSubmarineSound: cat > /dev/dsp exit=%d", [t terminationStatus]);
    } @catch (NSException *e) {
        NSLog(@"playSubmarineSound: cat > /dev/dsp threw %@", e);
    }
    [t release];
}

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        segments = [[NSMutableArray alloc] init];
        whisperCtx = NULL;
        state = WhisperStateIdle;
        downloadTask = nil;
        downloadData = nil;
        currentFilePath = nil;
        downloadingModel = nil;
        captureHandle = NULL;
        currentLangCode = nil;
        recordTimer = nil;
        streamTimer = nil;
        showTimestamps = NO;
        copyDefaultConsumed = NO;
        typedText = nil;
        vocabularyPrompt = [[[NSUserDefaults standardUserDefaults]
            stringForKey:@"VocabularyPrompt"] retain];
        if (!vocabularyPrompt) {
            vocabularyPrompt = [@"GNUstep AppImage" retain];
        }
        if (!xdoPath) {
            xdoPath = [[self findTool:@"xdotool"] retain];
            if (!xdoPath) xdoPath = @"/usr/bin/xdotool";
        }
        currentThreads = 8;

        [self populateModelList];
    }
    return self;
}

- (void)dealloc
{
    [self unloadModel];
    [segments release];
    [availableModels release];
    [currentFilePath release];
    [downloadingModel release];
    [downloadData release];
    [downloadFH release];
    [currentLangCode release];
    [recordTimer invalidate];
    [recordTimer release];
    [streamTimer invalidate];
    [streamTimer release];
    if (captureHandle) wcapture_cancel(captureHandle);
    [typedText release];
    [vocabularyPrompt release];
    [vocabPanel release];
    [super dealloc];
}

#pragma mark - App Delegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [self createUI];
    [self createMenu];

    // Restore last selected model (default: base.en) and set checkmark
    NSString *savedModel = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"LastModel"];
    if (!savedModel) {
        savedModel = @"ggml-base.en.bin";
        [[NSUserDefaults standardUserDefaults] setObject:savedModel forKey:@"LastModel"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    NSMenu *mainMenu = [NSApp mainMenu];
    NSMenuItem *appItem = [[mainMenu itemArray] objectAtIndex:0];
    NSMenu *appMenu = [appItem submenu];
    for (NSMenuItem *item in [appMenu itemArray]) {
        if ([[item title] isEqualToString:@"Model"]) {
            for (NSMenuItem *mi in [[item submenu] itemArray]) {
                if ([[mi representedObject] isEqualToString:savedModel]) {
                    [mi setState:NSOnState];
                } else {
                    [mi setState:NSOffState];
                }
            }
            break;
        }
    }

    // Restore last selected language (default: English)
    NSString *savedLang = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"LastLanguage"];
    if (!savedLang) savedLang = @"en";
    BOOL enModel = [savedModel hasSuffix:@".en"];
    NSString *langCode = enModel ? @"en" : savedLang;
    [currentLangCode release];
    currentLangCode = [langCode copy];

    // Restore thread count
    NSInteger savedThreads = [[NSUserDefaults standardUserDefaults]
        integerForKey:@"ThreadCount"];
    if (savedThreads >= 1 && savedThreads <= 32) {
        currentThreads = (int)savedThreads;
    }

    showTimestamps = [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowTimestamps"];
    [showTimestampsCheckbox setState:(showTimestamps ? NSOnState : NSOffState)];

    // Refresh checkmarks on model, language, and threads menus now that
    // saved preferences have been loaded.
    [self refreshMenuCheckmarks];

    [self updateUIForState];

    // ── Start-up dependency checks (before showing window) ────
    NSString *fail = nil;

    if (!wdlopen_init()) {
        NSString *sp = [[NSBundle mainBundle] pathForResource:@"build-whisper" ofType:@"sh"];
        if (!sp) sp = @"Whisper.app/Resources/build-whisper.sh";
        [self buildWhisperEngineWithScript:sp];
    } else if (![self findTool:@"xdotool"]) {
        fail = @"The xdotool tool is required for auto-typing into other windows.\n\n"
               @"Install it with your package manager:\n\n"
               @"  Debian/Ubuntu:  sudo apt install xdotool\n"
               @"  Arch:           sudo pacman -S xdotool\n"
               @"  FreeBSD:        sudo pkg install xdotool\n"
               @"  OpenBSD:        doas pkg_add xdotool";
    } else {
        NSString *mn = [[NSUserDefaults standardUserDefaults] stringForKey:@"LastModel"];
        if (mn) {
            NSString *mp = [self modelPathForName:mn];
            if (![[NSFileManager defaultManager] fileExistsAtPath:mp])
                [self downloadModelWithName:mn];
        }
    }

    if (fail) {
        NSAlert *a = [[NSAlert alloc] init];
        [a setMessageText:@"Missing dependencies"];
        [a setInformativeText:fail];
        [a addButtonWithTitle:@"OK"];
        [a runModal];
        [a release];
    }

    // If a build is in progress, finishStartup will be called from buildFinished:
    if (wdlopen_init())
        [self finishStartup];

}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self unloadModel];
    if (downloadTask && [downloadTask isRunning]) {
        [downloadTask terminate];
    }
    [recordTimer invalidate];
    [recordTimer release];
    recordTimer = nil;
    [streamTimer invalidate];
    [streamTimer release];
    streamTimer = nil;
    if (captureHandle) wcapture_cancel(captureHandle);
}

- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename
{
    [self setCurrentFilePath:filename];
    if (statusLabel) {
        [statusLabel setStringValue:filename];
    }
    return YES;
}

#pragma mark - Model Management

- (NSString *)modelDirPath
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if ([paths count] == 0) return nil;
    NSString *appSupport = [paths objectAtIndex:0];
    return [[appSupport stringByAppendingPathComponent:kWhisperModelDir]
               stringByStandardizingPath];
}

- (void)populateModelList
{
    NSMutableArray *models = [NSMutableArray array];
    for (int i = 0; modelNames[i] != NULL; i++) {
        NSString *name = [NSString stringWithUTF8String:modelNames[i]];
        NSString *label = [NSString stringWithUTF8String:modelSizes[i]];
        NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
            name, @"name", label, @"label", nil];
        [models addObject:entry];
    }
    [self setAvailableModels:models];
}

- (NSString *)modelPathForName:(NSString *)name
{
    NSString *dir = [self modelDirPath];
    if (!dir) return nil;
    return [dir stringByAppendingPathComponent:name];
}

- (BOOL)modelExists:(NSString *)name
{
    NSString *path = [self modelPathForName:name];
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (void)loadModel:(NSString *)modelPath
{
    if (whisperCtx) {
        [self unloadModel];
    }

    if (!wdlopen_init()) {
        NSLog(@"loadModel: whisper library not available");
        [self setState:WhisperStateError];
        [statusLabel setStringValue:@"whisper.cpp library not found"];
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        NSLog(@"loadModel: model file not found at %@", modelPath);
        [self setState:WhisperStateError];
        [statusLabel setStringValue:@"Model file not found"];
        return;
    }

    [self setState:WhisperStateLoadingModel];
    [statusLabel setStringValue:@"Loading model..."];

    // Try GPU first, fall back to CPU
    struct whisper_context_params cparams = wdlopen_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = true;

    NSLog(@"loadModel: trying GPU (%@)", modelPath);
    whisperCtx = wdlopen_init_from_file(
        [modelPath UTF8String], cparams);

    if (!whisperCtx) {
        NSLog(@"loadModel: GPU init failed, retrying with CPU");
        cparams.use_gpu = false;
        cparams.flash_attn = false;
        whisperCtx = wdlopen_init_from_file(
            [modelPath UTF8String], cparams);
        if (whisperCtx) {
            NSLog(@"loadModel: CPU init succeeded");
        }
    } else {
        NSLog(@"loadModel: GPU init succeeded");
    }

    if (!whisperCtx) {
        NSLog(@"loadModel: all backends failed for %@", modelPath);
        [self setState:WhisperStateError];
        [statusLabel setStringValue:@"Failed to load model"];

        // Check for corrupt/incomplete file
        NSString *fname = [modelPath lastPathComponent];
        unsigned long long fileSize = [[[NSFileManager defaultManager]
            attributesOfItemAtPath:modelPath error:NULL] fileSize];
        unsigned long long minSize = [self minimumModelSize:fname];
        if (fileSize > 0 && fileSize < minSize) {
            NSLog(@"loadModel: file is only %llu bytes (expected >= %llu) — likely truncated",
                  fileSize, minSize);
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Corrupt model file"];
            [alert setInformativeText:[NSString stringWithFormat:
                @"%@ appears to be only %llu MB (expected ≥ %llu MB).\n"
                "The download was probably interrupted.\n\n"
                "Click Download to re-download it.",
                fname, fileSize / 1000000, minSize / 1000000]];
            [alert addButtonWithTitle:@"Re-download"];
            [alert addButtonWithTitle:@"Cancel"];
            [alert setAlertStyle:NSCriticalAlertStyle];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                // Remove the corrupt file and re-download
                [[NSFileManager defaultManager] removeItemAtPath:modelPath
                                                          error:NULL];
                [self downloadModelWithName:
                    [[NSUserDefaults standardUserDefaults]
                        stringForKey:@"LastModel"]];
            }
            [alert release];
        } else {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Failed to load model"];
            [alert setInformativeText:[NSString stringWithFormat:
                @"Could not load %@.\n\nThe file may be corrupt. "
                @"Try downloading it again.", fname]];
            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
            [alert release];
        }
        return;
    }

    [self setState:WhisperStateIdle];
    [statusLabel setStringValue:[NSString stringWithFormat:
        @"Loaded %@", [modelPath lastPathComponent]]];
}

- (void)unloadModel
{
    if (whisperCtx) {
        wdlopen_free(whisperCtx);
        whisperCtx = NULL;
    }
}

// ── libcurl helpers ───────────────────────────────────────────
static size_t write_file_cb(void *ptr, size_t size, size_t nmemb, void *stream)
{
    return fwrite(ptr, size, nmemb, (FILE *)stream);
}

static int download_progress_cb(void *clientp,
                                curl_off_t dltotal, curl_off_t dlnow,
                                curl_off_t ultotal, curl_off_t ulnow)
{
    WhisperController *self = (WhisperController *)clientp;
    if (dltotal > 0) {
        static double lastPct = -1.0;
        double pct = (double)dlnow / (double)dltotal * 100.0;
        // Throttle: only update when percentage crosses an integer boundary
        if ((int)pct != (int)lastPct) {
            lastPct = pct;
            [self performSelectorOnMainThread:@selector(downloadProgressUpdated:)
                                   withObject:[NSNumber numberWithDouble:pct]
                                waitUntilDone:NO];
        }
    }
    return 0;
}

- (void)downloadModelWithName:(NSString *)name
{
    NSString *dir = [self modelDirPath];
    if (!dir) {
        [statusLabel setStringValue:@"Error: cannot find Application Support directory"];
        return;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    NSString *urlStr = [NSString stringWithFormat:
        @"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/%@",
        name];
    NSString *destPath = [dir stringByAppendingPathComponent:name];

    NSLog(@"downloadModelWithName: downloading %@", name);
    NSLog(@"downloadModelWithName: URL: %@", urlStr);
    NSLog(@"downloadModelWithName: dest: %@", destPath);

    [downloadProgress setDoubleValue:0.0];
    [downloadProgress setHidden:NO];
    [progressBar setIndeterminate:YES];
    [progressBar startAnimation:nil];
    [statusLabel setStringValue:[NSString stringWithFormat:
        @"Downloading %@", name]];
    [self setState:WhisperStateLoadingModel];

    [downloadingModel release];
    downloadingModel = [name retain];

    [self performSelectorInBackground:@selector(downloadThread:)
                           withObject:@[urlStr, destPath, name]];
}

- (void)downloadThread:(NSArray *)params
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *urlStr  = [params objectAtIndex:0];
    NSString *destPath = [params objectAtIndex:1];
    NSString *name    = [params objectAtIndex:2];

    static BOOL curlInit = NO;
    if (!curlInit) { curl_global_init(CURL_GLOBAL_DEFAULT); curlInit = YES; }

    CURL *curl = curl_easy_init();
    if (!curl) {
        NSLog(@"downloadThread: curl_easy_init failed");
        [self performSelectorOnMainThread:@selector(downloadFinishedWithError:)
                               withObject:@"Failed to initialize download"
                            waitUntilDone:NO];
        [pool release];
        return;
    }

    FILE *f = fopen([destPath fileSystemRepresentation], "wb");
    if (!f) {
        NSLog(@"downloadThread: cannot open %@ for writing", destPath);
        curl_easy_cleanup(curl);
        [self performSelectorOnMainThread:@selector(downloadFinishedWithError:)
                               withObject:[NSString stringWithFormat:@"Cannot write to %@", destPath]
                            waitUntilDone:NO];
        [pool release];
        return;
    }

    curl_easy_setopt(curl, CURLOPT_URL, [urlStr UTF8String]);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_file_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, f);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_RESUME_FROM, 0L);
    curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, download_progress_cb);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, self);

    NSLog(@"downloadThread: starting transfer...");
    CURLcode res = curl_easy_perform(curl);
    fclose(f);

    if (res == CURLE_OK) {
        NSLog(@"downloadThread: download complete");
        [self performSelectorOnMainThread:@selector(downloadFinishedWithName:)
                               withObject:name waitUntilDone:NO];
    } else {
        NSLog(@"downloadThread: curl error %d", res);
        NSString *err = [NSString stringWithUTF8String:curl_easy_strerror(res)];
        [self performSelectorOnMainThread:@selector(downloadFinishedWithError:)
                               withObject:err waitUntilDone:NO];
    }

    curl_easy_cleanup(curl);
    [pool release];
}

// Minimum expected file size (in bytes) for each model, at 90 % of declared
// size — a file smaller than this is almost certainly a truncated download.
static const unsigned long long modelMinSizes[] = {
    66 * 1000000,   // tiny.en    74 MB
    66 * 1000000,   // tiny       74 MB
    127 * 1000000,  // base.en   141 MB
    127 * 1000000,  // base      141 MB
    418 * 1000000,  // small.en  465 MB
    418 * 1000000,  // small     465 MB
    1278 * 1000000, // medium.en 1.42 GB
    1278 * 1000000, // medium    1.42 GB
    2583ULL * 1000000, // large-v3  2.87 GB
    728 * 1000000,  // large-v3-turbo 809 MB
};

- (unsigned long long)minimumModelSize:(NSString *)modelName
{
    for (int i = 0; modelNames[i] != NULL; i++) {
        if ([[NSString stringWithUTF8String:modelNames[i]]
                isEqualToString:modelName]) {
            return modelMinSizes[i];
        }
    }
    return 0;
}

- (void)downloadProgressUpdated:(NSNumber *)pct
{
    double v = [pct doubleValue];
    [downloadProgress setDoubleValue:v];
    [downloadProgress displayIfNeeded];
    [progressBar setIndeterminate:NO];
    [progressBar setDoubleValue:v];
    [progressBar displayIfNeeded];
    [statusLabel setStringValue:[NSString stringWithFormat:
        @"Downloading %@ — %.0f%%", downloadingModel, v]];
}

- (void)downloadFinishedWithName:(NSString *)name
{
    [downloadProgress setDoubleValue:100.0];
    [downloadProgress setHidden:YES];
    [progressBar stopAnimation:nil];
    [progressBar setIndeterminate:NO];
    [progressBar setDoubleValue:0.0];

    NSLog(@"downloadFinishedWithName: successfully downloaded %@", name);
    [statusLabel setStringValue:[NSString stringWithFormat:@"Downloaded %@", name]];
    [self loadModel:[self modelPathForName:name]];

    [downloadingModel release];
    downloadingModel = nil;
}

- (void)downloadFinishedWithError:(NSString *)error
{
    [downloadProgress setDoubleValue:100.0];
    [downloadProgress setHidden:YES];
    [progressBar stopAnimation:nil];
    [progressBar setIndeterminate:NO];
    [progressBar setDoubleValue:0.0];

    NSLog(@"downloadFinishedWithError: %@", error);
    [statusLabel setStringValue:[NSString stringWithFormat:@"Download failed: %@", error]];
    [self setState:WhisperStateError];

    [downloadingModel release];
    downloadingModel = nil;
}

#pragma mark - Audio Loading

- (float *)loadAudio:(NSString *)path outSamples:(int *)outNSamples
       outSampleRate:(int *)outSampleRate
{
    WAudioData *audio = waudio_load([path UTF8String]);
    if (!audio) {
        *outNSamples = 0;
        *outSampleRate = 0;
        return NULL;
    }

    float *samples = audio->samples;
    int n_samples = audio->n_samples;
    int sample_rate = audio->sample_rate;

    if (sample_rate != WHISPER_SAMPLE_RATE) {
        // Simple linear resampling to 16kHz
        double ratio = (double)WHISPER_SAMPLE_RATE / sample_rate;
        int new_n = (int)(n_samples * ratio);
        float *resampled = (float *)calloc(new_n, sizeof(float));

        for (int i = 0; i < new_n; i++) {
            double src_idx = i / ratio;
            int idx = (int)src_idx;
            double frac = src_idx - idx;
            if (idx + 1 < n_samples) {
                resampled[i] = (float)((1.0 - frac) * samples[idx]
                                       + frac * samples[idx + 1]);
            } else {
                resampled[i] = samples[idx];
            }
        }

        free(samples);
        samples = resampled;
        n_samples = new_n;
    }

    free(audio);
    *outNSamples = n_samples;
    *outSampleRate = WHISPER_SAMPLE_RATE;
    return samples;
}

#pragma mark - Transcription

- (IBAction)transcribe:(id)sender
{
    if (state == WhisperStateTranscribing || state == WhisperStateRecording) {
        return;
    }

    if (!currentFilePath) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No audio file selected"];
        [alert setInformativeText:@"Please open an audio file first."];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:currentFilePath]) {
        [statusLabel setStringValue:@"Error: file not found"];
        return;
    }

    if (!whisperCtx) {
        NSString *selectedName = [[NSUserDefaults standardUserDefaults]
            stringForKey:@"LastModel"];
        if (!selectedName) {
            [statusLabel setStringValue:@"Please select a model from the Whisper menu"];
            return;
        }
        NSString *modelPath = [self modelPathForName:selectedName];
        if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
            [statusLabel setStringValue:@"Model not downloaded — select from Whisper menu"];
            return;
        }
        [self loadModel:modelPath];
        if (!whisperCtx) return;
    }

    [[self segments] removeAllObjects];
    [typedText release]; typedText = nil;
    if (resultTextView) {
        [resultTextView setString:@""];
    }

    [self setState:WhisperStateTranscribing];
    [statusLabel setStringValue:@"Preparing..."];

    transcriptionStartTime = [NSDate timeIntervalSinceReferenceDate];

    [NSThread detachNewThreadSelector:@selector(transcriptionThread:)
                             toTarget:self
                           withObject:nil];
}

- (void)transcriptionThread:(id)object
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    int n_samples = 0;
    int sample_rate = 0;
    float *samples = [self loadAudio:currentFilePath
                          outSamples:&n_samples
                        outSampleRate:&sample_rate];

    if (!samples) {
        [self performSelectorOnMainThread:@selector(transcriptionFailed:)
                               withObject:@"Failed to decode audio file"
                            waitUntilDone:NO];
        [pool release];
        return;
    }

    struct whisper_full_params wparams = wdlopen_full_default_params(
        WHISPER_SAMPLING_GREEDY);

    wparams.n_threads = currentThreads;

    NSString *langCode = currentLangCode;
    if (langCode && ![langCode isEqualToString:@"auto"]) {
        wparams.language = [langCode UTF8String];
        wparams.detect_language = false;
    } else {
        wparams.detect_language = false;
        wdlopen_pcm_to_mel(whisperCtx, samples, n_samples, wparams.n_threads);
        int lang_id = wdlopen_lang_auto_detect(whisperCtx, 0, wparams.n_threads, NULL);
        if (lang_id >= 0) {
            wparams.language = wdlopen_lang_str(lang_id);
        } else {
            wparams.language = "en";
        }
    }

    wparams.no_timestamps = false;
    wparams.print_progress = false;
    wparams.print_realtime = false;
    wparams.print_special = false;

    // Stream segments live as whisper decodes them
    wparams.new_segment_callback = whisper_new_segment_cb;
    wparams.new_segment_callback_user_data = self;

    wparams.progress_callback = whisper_progress_cb;
    wparams.progress_callback_user_data = self;

    if (vocabularyPrompt) {
        wparams.initial_prompt = [vocabularyPrompt UTF8String];
        wparams.carry_initial_prompt = true;
    }

    int ret = wdlopen_full(whisperCtx, wparams, samples, n_samples);

    free(samples);

    if (ret != 0) {
        [self performSelectorOnMainThread:@selector(transcriptionFailed:)
                               withObject:@"Transcription failed"
                            waitUntilDone:NO];
        [pool release];
        return;
    }

    // Segments were added incrementally by whisper_new_segment_cb → appendStreamingResult:

    [self performSelectorOnMainThread:@selector(transcriptionFinished:)
                           withObject:nil
                        waitUntilDone:NO];
    [pool release];
}

- (void)transcriptionProgress:(NSNumber *)progress
{
    int p = [progress intValue];
    [progressBar setDoubleValue:(double)p];
    if (p < 100) {
        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate]
                                 - transcriptionStartTime;
        int remaining = (int)(elapsed * (100.0 - p) / p);
        [statusLabel setStringValue:[NSString stringWithFormat:
            @"Transcribing... %d%% (≈%d s remaining)", p, remaining]];
    }
}

- (void)transcriptionFinished:(NSString *)result
{
    [progressBar setDoubleValue:100.0];
    [self setState:WhisperStateDone];
    [statusLabel setStringValue:@"Done"];

    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate]
                             - transcriptionStartTime;
    [statusLabel setStringValue:[NSString stringWithFormat:
        @"Done (%.1f s)", elapsed]];

    [self rebuildTextView];
    [self syncTypedText];
}

- (void)streamingFlushDone
{
    if (captureHandle) return;
    if ([segments count] == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No speech detected"];
        [alert setInformativeText:@"The microphone did not pick up any recognizable speech."];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
        return;
    }
    [self syncTypedText];
}

- (void)transcriptionFailed:(NSString *)error
{
    [self setState:WhisperStateError];
    [statusLabel setStringValue:error];
}

#pragma mark - UI State

- (void)setState:(WhisperState)newState
{
    state = newState;
    [self updateUIForState];
}

- (void)updateUIForState
{
    BOOL isWorking = (state == WhisperStateLoadingModel ||
                      state == WhisperStateTranscribing);
    BOOL isRecording = (state == WhisperStateRecording);

    if (isRecording) {
        [recordSpinner startAnimation:nil];
        [progressBar setIndeterminate:YES];
        [progressBar startAnimation:nil];
    } else {
        [recordSpinner stopAnimation:nil];
        [progressBar stopAnimation:nil];
        [progressBar setIndeterminate:NO];
        if (!isWorking) {
            [progressBar setDoubleValue:0.0];
        }
    }

    // enModel check is done in modelSelected:
    // [translateCheckbox setEnabled:(!isWorking && !isRecording)];
    [recordButton setEnabled:(!isRecording && !isWorking)];
    [stopButton setEnabled:isRecording];

    BOOL hasResults = [segments count] > 0;
    [copyTextButton setEnabled:hasResults];

    // No button responds to Enter (avoids accidental re-trigger after alerts)
    [recordButton setKeyEquivalent:@""];
    [stopButton setKeyEquivalent:@""];
    [copyTextButton setKeyEquivalent:@""];
    [mainWindow setDefaultButtonCell:nil];

}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL a = [item action];
    if (a == NULL) return YES; // Submenu title
    BOOL hasRes = [segments count] > 0;
    if (a == @selector(saveAsTxt:) ||
        a == @selector(saveAsSrt:) ||
        a == @selector(saveAsVtt:)) {
        return hasRes;
    }
    // Standard edit actions are handled by the text view responder
    if (a == @selector(cut:) || a == @selector(copy:) ||
        a == @selector(paste:) || a == @selector(selectAll:)) {
        return [resultTextView isEditable];
    }
    return YES;
}

#pragma mark - Actions

- (IBAction)recordAudio:(id)sender
{
    if (captureHandle) {
        NSLog(@"recordAudio: already recording (handle=%p)", captureHandle);
        return;
    }

    NSLog(@"recordAudio: starting capture at 16kHz");
    int sr = 16000;
    // Find the active SoundBackend (same selection as Sound PrefPane)
    id<SoundBackend> snd = nil;
    NSString *devPath = nil;  // ALSA: "plughw:N,M" — OSS: "/dev/dspN"

#if defined(__FreeBSD__) || defined(__DragonFly__) || defined(__OpenBSD__) || defined(__NetBSD__)
    OSSBackend *oss = [[OSSBackend alloc] init];
    if ([oss isAvailable]) {
        snd = oss;
        AudioDevice *dev = [oss defaultInputDevice];
        if (dev) {
            devPath = [NSString stringWithFormat:@"/dev/dsp%d", [dev cardIndex]];
        }
        NSLog(@"recordAudio: using OSS backend, device=%@", devPath);
    } else {
        [oss release];
    }
#endif
    if (!snd) {
        ALSABackend *alsa = [[ALSABackend alloc] init];
        if ([alsa isAvailable]) {
            snd = alsa;
            AudioDevice *dev = [alsa defaultInputDevice];
            if (dev) {
                devPath = [NSString stringWithFormat:@"plughw:%d,%d",
                                    [dev cardIndex], [dev deviceIndex]];
            }
            NSLog(@"recordAudio: using ALSA backend, device=%@", devPath);
        } else {
            [alsa release];
        }
    }
#if !defined(__FreeBSD__) && !defined(__DragonFly__) && !defined(__OpenBSD__) && !defined(__NetBSD__)
    if (!snd) {
        OSSBackend *oss = [[OSSBackend alloc] init];
        if ([oss isAvailable]) {
            snd = oss;
            AudioDevice *dev = [oss defaultInputDevice];
            if (dev) {
                devPath = [NSString stringWithFormat:@"/dev/dsp%d", [dev cardIndex]];
            }
            NSLog(@"recordAudio: using OSS fallback backend, device=%@", devPath);
        } else {
            [oss release];
        }
    }
#endif
    [snd release];

    captureHandle = wcapture_start(sr, [devPath UTF8String]);
    if (!captureHandle) {
        NSLog(@"recordAudio: wcapture_start returned NULL");
        [statusLabel setStringValue:@"No microphone found"];
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No microphone available"];
        [alert setInformativeText:@"Connect a microphone to record audio for transcription."];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
        return;
    }

    // Ensure model is loaded before recording
    if (!whisperCtx) {
        NSLog(@"recordAudio: no model loaded, loading now...");
        NSString *selectedName = [[NSUserDefaults standardUserDefaults]
            stringForKey:@"LastModel"];
        if (!selectedName) {
            NSLog(@"recordAudio: no model selected, canceling capture");
            wcapture_cancel(captureHandle);
            captureHandle = NULL;
            [statusLabel setStringValue:@"Please select a model from the Whisper menu"];
            return;
        }
        NSString *modelPath = [self modelPathForName:selectedName];
        if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
            NSLog(@"recordAudio: model '%@' not downloaded", selectedName);
            wcapture_cancel(captureHandle);
            captureHandle = NULL;

            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Model not downloaded"];
            [alert setInformativeText:[NSString stringWithFormat:
                @"The model \"%@\" needs to be downloaded first.\n\n"
                @"Download it now?", selectedName]];
            [alert addButtonWithTitle:@"Download"];
            [alert addButtonWithTitle:@"Cancel"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [self downloadModelWithName:selectedName];
            }
            [alert release];
            return;
        }
        [self loadModel:modelPath];
        if (!whisperCtx) {
            NSLog(@"recordAudio: model loading failed, canceling capture");
            wcapture_cancel(captureHandle);
            captureHandle = NULL;
            return;
        }
    }

    NSLog(@"recordAudio: capture started, handle=%p", captureHandle);
    [self playSubmarineSound];
    copyDefaultConsumed = NO;
    [typedText release]; typedText = nil;

    // Save target window for xdotool so it types into the correct app
    {
        FILE *fp = popen("xdotool getactivewindow 2>/dev/null", "r");
        if (fp) {
            char buf[32];
            if (fgets(buf, sizeof(buf), fp)) {
                targetWindowID = strtoul(buf, NULL, 10);
                NSLog(@"recordAudio: target window = %lu", targetWindowID);
            }
            pclose(fp);
        }
    }

    [self setState:WhisperStateRecording];
    recordStartTime = [NSDate timeIntervalSinceReferenceDate];
    lastSegmentCount = 0;
    [statusLabel setStringValue:@"Recording 00:00"];

    // Clear previous results
    [[self segments] removeAllObjects];
    if (resultTextView) {
        [resultTextView setString:@""];
    }

    // Update elapsed time every second
    [recordTimer invalidate];
    [recordTimer release];
    recordTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                    target:self
                                                  selector:@selector(recordTimerFired:)
                                                  userInfo:nil
                                                   repeats:YES] retain];

    // Streaming transcription every 5 seconds (needs enough audio for whisper)
    [streamTimer invalidate];
    [streamTimer release];
    streamTimer = [[NSTimer scheduledTimerWithTimeInterval:5.0
                                                    target:self
                                                  selector:@selector(streamTimerFired:)
                                                  userInfo:nil
                                                   repeats:YES] retain];
    NSLog(@"recordAudio: timers started (record=1s, stream=3s)");
}

- (IBAction)stopRecording:(id)sender
{
    if (!captureHandle) {
        NSLog(@"stopRecording: no capture handle");
        return;
    }

    NSLog(@"stopRecording: stopping capture...");
    [recordTimer invalidate];
    [recordTimer release];
    recordTimer = nil;
    [streamTimer invalidate];
    [streamTimer release];
    streamTimer = nil;

    WCaptureData *capData = wcapture_stop(captureHandle);
    captureHandle = NULL;
    [self playSubmarineSound];

    if (!capData || capData->n_samples == 0) {
        NSLog(@"stopRecording: no audio captured");
        wcapture_free_data(capData);
        [statusLabel setStringValue:@"No audio captured"];
        [self setState:WhisperStateIdle];
        return;
    }

    NSLog(@"stopRecording: got %d samples at %d Hz",
          capData->n_samples, capData->sample_rate);

    [self setState:WhisperStateIdle];
    [statusLabel setStringValue:@"Recording stopped"];

    // Save as current file path for later reuse
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *tmpPath = [tmpDir stringByAppendingPathComponent:@"whisper_recording.wav"];
    [self setCurrentFilePath:tmpPath];
    [statusLabel setStringValue:@"[Microphone]"];

    // Do a final flush transcription
    if (whisperCtx && capData->n_samples > 0) {
        NSLog(@"stopRecording: final flush with %d samples", capData->n_samples);
        NSData *pcmData = [NSData dataWithBytes:capData->samples
                                         length:capData->n_samples * sizeof(float)];
        [self performSelectorInBackground:@selector(transcribeStreamingChunk:)
                               withObject:pcmData];
    } else if (!whisperCtx) {
        NSLog(@"stopRecording: whisperCtx is NULL, no model loaded");
    }

    wcapture_free_data(capData);
}

- (void)recordTimerFired:(NSTimer *)timer
{
    if (!captureHandle) {
        [timer invalidate];
        return;
    }
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - recordStartTime;
    int sec = (int)elapsed;
    int min = sec / 60;
    sec %= 60;
    [statusLabel setStringValue:[NSString stringWithFormat:
        @"Recording %02d:%02d", min, sec]];
}

- (void)streamTimerFired:(NSTimer *)timer
{
    if (!captureHandle) {
        NSLog(@"streamTimerFired: no capture handle");
        return;
    }
    if (!whisperCtx) {
        NSLog(@"streamTimerFired: no whisper context loaded");
        return;
    }

    NSLog(@"streamTimerFired: taking snapshot...");
    float *samples = NULL;
    int n = wcapture_snapshot(captureHandle, &samples);
    if (n <= 0 || !samples) {
        NSLog(@"streamTimerFired: snapshot returned %d samples", n);
        return;
    }

    NSLog(@"streamTimerFired: got %d samples (%.1f seconds), dispatching",
          n, (float)n / 16000.0f);
    NSData *pcmData = [NSData dataWithBytesNoCopy:samples length:n * sizeof(float)
                                    freeWhenDone:YES];
    [self performSelectorInBackground:@selector(transcribeStreamingChunk:)
                           withObject:pcmData];
}

- (void)transcribeStreamingChunk:(NSData *)pcmData
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    // Serialise: only one whisper_full at a time on the same context
    if (isTranscribing) {
        NSLog(@"transcribeStreamingChunk: skip — already transcribing");
        [pool release];
        return;
    }
    isTranscribing = YES;

    float *samples = (float *)[pcmData bytes];
    int n = (int)([pcmData length] / sizeof(float));

    if (!whisperCtx) {
        NSLog(@"transcribeStreamingChunk: whisperCtx is NULL");
        [pool release];
        return;
    }
    if (n == 0) {
        NSLog(@"transcribeStreamingChunk: empty PCM data");
        [pool release];
        return;
    }

    // Check audio level
    float peak = 0.0f;
    for (int i = 0; i < n; i++) {
        float absv = fabsf(samples[i]);
        if (absv > peak) peak = absv;
    }
    NSLog(@"transcribeStreamingChunk: %d samples (%.1f sec), peak=%.6f",
          n, (float)n / 16000.0f, peak);

    struct whisper_full_params wparams = wdlopen_full_default_params(
        WHISPER_SAMPLING_GREEDY);

    wparams.n_threads = currentThreads;

    // Read language from ivar (set on main thread, safe for background read)
    NSString *langCode = currentLangCode;
    if (langCode && ![langCode isEqualToString:@"auto"]) {
        wparams.language = [langCode UTF8String];
        wparams.detect_language = false;
        NSLog(@"transcribeStreamingChunk: language=%@", langCode);
    } else {
        wparams.detect_language = false;
        wdlopen_pcm_to_mel(whisperCtx, samples, n, wparams.n_threads);
        int lang_id = wdlopen_lang_auto_detect(whisperCtx, 0, wparams.n_threads, NULL);
        if (lang_id >= 0) {
            wparams.language = wdlopen_lang_str(lang_id);
        } else {
            wparams.language = "en";
        }
        NSLog(@"transcribeStreamingChunk: auto-detected language=%s", wparams.language);
    }

    // wparams.translate = [translateCheckbox state] == NSOnState ? true : false;
    wparams.no_timestamps = false;
    wparams.print_progress = false;
    wparams.print_realtime = false;
    wparams.print_special = false;
    wparams.new_segment_callback = whisper_new_segment_cb;
    wparams.new_segment_callback_user_data = self;

    if (vocabularyPrompt) {
        wparams.initial_prompt = [vocabularyPrompt UTF8String];
        wparams.carry_initial_prompt = true;
    }

    NSLog(@"transcribeStreamingChunk: calling whisper_full (segments appear via callback)...");
    int ret = wdlopen_full(whisperCtx, wparams, samples, n);
    NSLog(@"transcribeStreamingChunk: whisper_full returned %d", ret);

    lastSegmentCount = wdlopen_full_n_segments(whisperCtx);
    NSLog(@"transcribeStreamingChunk: done, total segments=%d", lastSegmentCount);

    // If whisper detected silence, stop recording
    if (captureHandle) {
        for (int i = 0; i < lastSegmentCount; i++) {
            const char *segText = wdlopen_full_get_segment_text(whisperCtx, i);
            if (segText && (strcasestr(segText, "[silence]") || strcasestr(segText, "[BLANK_AUDIO]"))) {
                NSLog(@"transcribeStreamingChunk: silence detected, stopping");
                [self performSelectorOnMainThread:@selector(stopRecording:)
                                       withObject:nil
                                    waitUntilDone:NO];
                break;
            }
        }
    }

    [self performSelectorOnMainThread:@selector(syncTypedText)
                           withObject:nil
                        waitUntilDone:NO];

    isTranscribing = NO;

    // If capture is gone (recording stopped), this was the final flush
    if (!captureHandle) {
        [self performSelectorOnMainThread:@selector(streamingFlushDone)
                               withObject:nil
                            waitUntilDone:NO];
    }
    [pool release];
}

- (void)appendStreamingResult:(NSDictionary *)result
{
    NSArray *newSegs = [result objectForKey:@"segments"];

    NSLog(@"appendStreamingResult: %lu new segments",
          (unsigned long)[newSegs count]);

    // Remove existing segments that overlap in time with incoming
    // segments, then add the new ones (except silence).
    for (NSDictionary *seg in newSegs) {
        NSString *txt = [seg objectForKey:@"text"];
        if (txt && ([txt rangeOfString:@"[silence]"
                               options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [txt rangeOfString:@"[BLANK_AUDIO]"
                               options:NSCaseInsensitiveSearch].location != NSNotFound))
            continue;
        int64_t newT0 = [[seg objectForKey:@"t0"] longLongValue];
        int64_t newT1 = [[seg objectForKey:@"t1"] longLongValue];
        for (NSInteger i = [segments count] - 1; i >= 0; i--) {
            NSDictionary *existing = [segments objectAtIndex:i];
            int64_t exT0 = [[existing objectForKey:@"t0"] longLongValue];
            int64_t exT1 = [[existing objectForKey:@"t1"] longLongValue];
            if (newT0 < exT1 && newT1 > exT0) {
                [segments removeObjectAtIndex:i];
            }
        }
        [segments addObject:seg];
    }

    [segments sortUsingComparator:^(id a, id b) {
        int64_t t0a = [[(NSDictionary *)a objectForKey:@"t0"] longLongValue];
        int64_t t0b = [[(NSDictionary *)b objectForKey:@"t0"] longLongValue];
        if (t0a < t0b) return NSOrderedAscending;
        if (t0a > t0b) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    [self rebuildTextView];
    NSLog(@"appendStreamingResult: rebuilt text view (%lu segments)",
          (unsigned long)[segments count]);
    [self updateUIForState];
}

// Transcribe raw PCM data and append only new segments to the UI.
// Runs synchronously on the calling thread (should be main thread for streaming).

- (IBAction)openFile:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:NO];
    [panel setCanChooseDirectories:NO];
    [panel setCanChooseFiles:YES];

    NSArray *types = [NSArray arrayWithObjects:
        @"wav", @"mp3", @"flac", @"ogg", @"m4a", @"aac", @"wma", nil];
    [panel setAllowedFileTypes:types];

    if ([panel runModal] == NSOKButton) {
        NSString *path = [[panel URL] path];
        [self setCurrentFilePath:path];
        [statusLabel setStringValue:path];
        [self setState:WhisperStateIdle];
        [self transcribe:nil];
    }
}

- (IBAction)modelSelected:(id)sender
{
    NSString *name = [sender representedObject];
    if (!name) return;

    [[NSUserDefaults standardUserDefaults] setObject:name forKey:@"LastModel"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"modelSelected: saved '%@' as last model", name);

    // Update checkmarks in the Model menu
    NSMenu *modelMenu = [sender menu];
    for (NSMenuItem *item in [modelMenu itemArray]) {
        [item setState:([[item representedObject] isEqualToString:name]
                        ? NSOnState : NSOffState)];
    }

    // Auto-download if not present
    NSString *modelPath = [self modelPathForName:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        [self downloadModelWithName:name];
    }

    // Models ending in .en only support English
    BOOL isEN = [name hasSuffix:@".en"];
    if (isEN) {
        [currentLangCode release];
        currentLangCode = [@"en" copy];
        [[NSUserDefaults standardUserDefaults] setObject:@"en"
                                                   forKey:@"LastLanguage"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

- (IBAction)languageChanged:(id)sender
{
    NSString *code = [sender representedObject];
    if (!code) return;
    [currentLangCode release];
    currentLangCode = [code copy];
    [[NSUserDefaults standardUserDefaults] setObject:code
                                               forKey:@"LastLanguage"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"languageChanged: saved '%@'", code);
    // Update checkmarks
    NSMenu *parent = [sender menu];
    for (NSMenuItem *item in [parent itemArray]) {
        [item setState:([[item representedObject] isEqualToString:code]
                        ? NSOnState : NSOffState)];
    }
}

- (IBAction)threadSelected:(id)sender
{
    currentThreads = (int)[sender tag];
    [[NSUserDefaults standardUserDefaults] setInteger:currentThreads
                                               forKey:@"ThreadCount"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    // Update checkmark in the Threads submenu
    NSMenu *parent = [sender menu];
    for (NSMenuItem *item in [parent itemArray]) {
        [item setState:([item tag] == currentThreads ? NSOnState : NSOffState)];
    }
}

- (IBAction)saveAsTxt:(id)sender
{
    [self saveTranscriptionWithFormat:@"txt"];
    copyDefaultConsumed = YES;
    [self updateUIForState];
}

- (IBAction)saveAsSrt:(id)sender
{
    [self saveTranscriptionWithFormat:@"srt"];
    copyDefaultConsumed = YES;
    [self updateUIForState];
}

- (IBAction)saveAsVtt:(id)sender
{
    [self saveTranscriptionWithFormat:@"vtt"];
    copyDefaultConsumed = YES;
    [self updateUIForState];
}

- (IBAction)copyText:(id)sender
{
    NSString *text = [resultTextView string];
    if ([text length] == 0) return;

    NSMutableString *stripped = [NSMutableString string];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    while (![scanner isAtEnd]) {
        NSString *line;
        [scanner scanUpToString:@"\n" intoString:&line];
        if (![scanner isAtEnd]) [scanner scanString:@"\n" intoString:NULL];

        // Strip leading timestamp [HH:MM:SS.mm --> HH:MM:SS.mm]
        NSRange tsRange = [line rangeOfString:@"] "];
        if (tsRange.location != NSNotFound) {
            line = [line substringFromIndex:tsRange.location + 2];
        }
        [stripped appendString:line];
        [stripped appendString:@"\n"];
    }
    // Remove trailing newline
    if ([stripped hasSuffix:@"\n"]) {
        [stripped deleteCharactersInRange:NSMakeRange([stripped length] - 1, 1)];
    }

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [pb setString:stripped forType:NSStringPboardType];
    copyDefaultConsumed = YES;
    [self updateUIForState];
}

- (IBAction)timestampsToggled:(id)sender
{
    showTimestamps = ([sender state] == NSOnState);
    [[NSUserDefaults standardUserDefaults] setBool:showTimestamps
                                            forKey:@"ShowTimestamps"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self rebuildTextView];
}

#pragma mark - Vocabulary

- (IBAction)editVocabulary:(id)sender
{
    if (!vocabPanel) {
        vocabPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 320)
                                                styleMask:NSTitledWindowMask
                                                          | NSClosableWindowMask
                                                          | NSResizableWindowMask
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        [vocabPanel setTitle:@"Custom Vocabulary"];
        [vocabPanel setFloatingPanel:NO];
        [vocabPanel setHidesOnDeactivate:NO];
        [vocabPanel setDelegate:self];

        NSView *cv = [vocabPanel contentView];
        [cv setAutoresizesSubviews:YES];

        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 40, 400, 260)];
        [sv setHasVerticalScroller:YES];
        [sv setBorderType:NSBezelBorder];
        [sv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        vocabTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 260)];
        [vocabTextView setFont:[NSFont userFixedPitchFontOfSize:12]];
        [vocabTextView setVerticallyResizable:YES];
        [vocabTextView setHorizontallyResizable:NO];
        [[vocabTextView textContainer] setWidthTracksTextView:YES];
        [sv setDocumentView:vocabTextView];
        [cv addSubview:sv];
        [sv release];

        NSButton *saveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(320, 10, 90, 24)];
        [saveBtn setTitle:@"Save"];
        [saveBtn setBezelStyle:NSRoundedBezelStyle];
        [saveBtn setTarget:self];
        [saveBtn setAction:@selector(saveVocabulary:)];
        [saveBtn setAutoresizingMask:NSViewMinXMargin];
        [cv addSubview:saveBtn];
        [saveBtn release];

        NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(230, 10, 80, 24)];
        [cancelBtn setTitle:@"Cancel"];
        [cancelBtn setBezelStyle:NSRoundedBezelStyle];
        [cancelBtn setTarget:self];
        [cancelBtn setAction:@selector(cancelVocabulary:)];
        [cancelBtn setAutoresizingMask:NSViewMinXMargin];
        [cv addSubview:cancelBtn];
        [cancelBtn release];
    }

    [vocabTextView setString:vocabularyPrompt ? vocabularyPrompt : @""];
    [vocabPanel makeKeyAndOrderFront:self];
}

- (void)saveVocabulary:(id)sender
{
    NSString *text = [vocabTextView string];
    [vocabularyPrompt release];
    vocabularyPrompt = [text retain];
    [[NSUserDefaults standardUserDefaults] setObject:text forKey:@"VocabularyPrompt"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [vocabPanel close];
}

- (void)cancelVocabulary:(id)sender
{
    [vocabPanel close];
}

- (NSString *)displayTextFromSegments
{
    NSMutableString *result = [NSMutableString string];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSDictionary *seg in segments) {
        NSString *txt = [seg objectForKey:@"text"];
        if (!txt) continue;
        NSUInteger i = 0;
        while (i < [txt length] && [ws characterIsMember:[txt characterAtIndex:i]])
            i++;
        if (i >= [txt length]) continue;
        txt = [txt substringFromIndex:i];
        if (showTimestamps) {
            int64_t t0 = [[seg objectForKey:@"t0"] longLongValue];
            int64_t t1 = [[seg objectForKey:@"t1"] longLongValue];
            NSString *ts = [NSString stringWithFormat:@"[%@ --> %@] ",
                              [self formatTimestamp:t0],
                              [self formatTimestamp:t1]];
            if ([result length] > 0) [result appendString:@" "];
            [result appendString:ts];
            [result appendString:txt];
        } else {
            if ([result length] > 0) [result appendString:@" "];
            [result appendString:txt];
        }
    }
    return result;
}

- (void)rebuildTextView
{
    if (!resultTextView) return;
    NSString *text = [self displayTextFromSegments];
    [resultTextView setString:text];
    [resultTextView scrollRangeToVisible:NSMakeRange([text length], 0)];
}

#pragma mark - Export

- (NSString *)formatTimestamp:(int64_t)t
{
    int ms = (int)(t % 100);
    int sec = (int)((t / 100) % 60);
    int min = (int)((t / 6000) % 60);
    int hr = (int)(t / 360000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d.%02d", hr, min, sec, ms];
}

- (NSString *)formatTimestampSrt:(int64_t)t
{
    int ms = (int)(t % 100) * 10;
    int sec = (int)((t / 100) % 60);
    int min = (int)((t / 6000) % 60);
    int hr = (int)(t / 360000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d,%03d", hr, min, sec, ms];
}

- (NSString *)formatTimestampVtt:(int64_t)t
{
    int ms = (int)(t % 100) * 10;
    int sec = (int)((t / 100) % 60);
    int min = (int)((t / 6000) % 60);
    int hr = (int)(t / 360000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d.%03d", hr, min, sec, ms];
}

- (void)saveTranscriptionWithFormat:(NSString *)format
{
    if ([segments count] == 0) return;

    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setAllowedFileTypes:[NSArray arrayWithObject:format]];
    [panel setExtensionHidden:NO];

    if (currentFilePath) {
        NSString *base = [[currentFilePath lastPathComponent]
                            stringByDeletingPathExtension];
        [panel setNameFieldStringValue:[base stringByAppendingPathExtension:format]];
    }

    if ([panel runModal] != NSOKButton) return;

    NSString *path = [[panel URL] path];
    NSMutableString *content = [NSMutableString string];

    if ([format isEqualToString:@"srt"]) {
        for (int i = 0; i < [segments count]; i++) {
            NSDictionary *seg = [segments objectAtIndex:i];
            int64_t t0 = [[seg objectForKey:@"t0"] longLongValue];
            int64_t t1 = [[seg objectForKey:@"t1"] longLongValue];
            NSString *text = [seg objectForKey:@"text"];
            [content appendFormat:@"%d\n%@ --> %@\n%@\n\n",
                i + 1,
                [self formatTimestampSrt:t0],
                [self formatTimestampSrt:t1],
                text];
        }
    } else if ([format isEqualToString:@"vtt"]) {
        [content appendString:@"WEBVTT\n\n"];
        for (int i = 0; i < [segments count]; i++) {
            NSDictionary *seg = [segments objectAtIndex:i];
            int64_t t0 = [[seg objectForKey:@"t0"] longLongValue];
            int64_t t1 = [[seg objectForKey:@"t1"] longLongValue];
            NSString *text = [seg objectForKey:@"text"];
            [content appendFormat:@"%@ --> %@\n%@\n\n",
                [self formatTimestampVtt:t0],
                [self formatTimestampVtt:t1],
                text];
        }
    } else {
        for (int i = 0; i < [segments count]; i++) {
            NSDictionary *seg = [segments objectAtIndex:i];
            int64_t t0 = [[seg objectForKey:@"t0"] longLongValue];
            int64_t t1 = [[seg objectForKey:@"t1"] longLongValue];
            NSString *text = [seg objectForKey:@"text"];
            [content appendFormat:@"[%@ --> %@] %@\n",
                [self formatTimestamp:t0],
                [self formatTimestamp:t1],
                text];
        }
    }

    NSError *error = nil;
    BOOL ok = [content writeToFile:path
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:&error];
    if (!ok) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Save failed"];
        [alert setInformativeText:[error localizedDescription]];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
    }
}

#pragma mark - NSTableView (model list)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return [availableModels count];
}

- (id)tableView:(NSTableView *)tableView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
                          row:(NSInteger)row
{
    NSDictionary *entry = [availableModels objectAtIndex:row];
    return [entry objectForKey:@"label"];
}

#pragma mark - Menu

- (void)createMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // Application menu
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Whisper"];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Whisper"
                                                     action:NULL
                                              keyEquivalent:@""];
    [appItem setSubmenu:appMenu];
    [mainMenu addItem:appItem];

    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About Whisper"
                                                       action:@selector(orderFrontStandardAboutPanel:)
                                                keyEquivalent:@""];
    [aboutItem setTarget:NSApp];
    [appMenu addItem:aboutItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Transcribe file..."
                                                      action:@selector(openFile:)
                                               keyEquivalent:@"o"];
    [appMenu addItem:openItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    // Model submenu
    NSMenu *modelMenu = [[NSMenu alloc] initWithTitle:@"Model"];
    NSMenuItem *modelMenuItem = [[NSMenuItem alloc] initWithTitle:@"Model"
                                                           action:NULL
                                                    keyEquivalent:@""];
    [modelMenuItem setSubmenu:modelMenu];
    [appMenu addItem:modelMenuItem];

    for (int i = 0; modelNames[i] != NULL; i++) {
        NSString *label = [NSString stringWithUTF8String:modelSizes[i]];
        NSString *name = [NSString stringWithUTF8String:modelNames[i]];
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:label
                                                    action:@selector(modelSelected:)
                                             keyEquivalent:@""];
        [mi setRepresentedObject:name];
        [mi setTarget:self];
        [modelMenu addItem:mi];
        [mi release];
    }

    // Threads submenu
    int threadValues[] = {1, 2, 4, 8, 16, 32};
    NSMenu *threadMenu = [[NSMenu alloc] initWithTitle:@"Threads"];
    NSMenuItem *threadMenuItem = [[NSMenuItem alloc] initWithTitle:@"Threads"
                                                            action:NULL
                                                     keyEquivalent:@""];
    [threadMenuItem setSubmenu:threadMenu];
    [appMenu addItem:threadMenuItem];
    for (int i = 0; i < 6; i++) {
        int tv = threadValues[i];
        NSString *title = [NSString stringWithFormat:@"%d", tv];
        NSMenuItem *ti = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(threadSelected:)
                                             keyEquivalent:@""];
        [ti setTag:tv];
        [ti setTarget:self];
        [ti setState:(tv == currentThreads ? NSOnState : NSOffState)];
        [threadMenu addItem:ti];
        [ti release];
    }
    [threadMenuItem release];
    [threadMenu release];

    // Language submenu
    NSMenu *langMenu = [[NSMenu alloc] initWithTitle:@"Language"];
    NSMenuItem *langMenuItem = [[NSMenuItem alloc] initWithTitle:@"Language"
                                                          action:NULL
                                                   keyEquivalent:@""];
    [langMenuItem setSubmenu:langMenu];
    [appMenu addItem:langMenuItem];
    for (int i = 0; langCodes[i] != NULL; i++) {
        NSString *label = [NSString stringWithUTF8String:langNames[i]];
        NSString *code = [NSString stringWithUTF8String:langCodes[i]];
        NSMenuItem *li = [[NSMenuItem alloc] initWithTitle:label
                                                    action:@selector(languageChanged:)
                                             keyEquivalent:@""];
        [li setRepresentedObject:code];
        [li setTarget:self];
        [li setState:[code isEqualToString:currentLangCode]
            ? NSOnState : NSOffState];
        [langMenu addItem:li];
        [li release];
    }
    [langMenuItem release];
    [langMenu release];

    NSMenuItem *vocabItem = [[NSMenuItem alloc] initWithTitle:@"Vocabulary..."
                                                       action:@selector(editVocabulary:)
                                                keyEquivalent:@""];
    [vocabItem setTarget:self];
    [appMenu addItem:vocabItem];
    [vocabItem release];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *saveTxtItem = [[NSMenuItem alloc] initWithTitle:@"Save as TXT"
                                                         action:@selector(saveAsTxt:)
                                                  keyEquivalent:@"s"];
    [saveTxtItem setTarget:self];
    [appMenu addItem:saveTxtItem];
    [saveTxtItem release];

    NSMenuItem *saveSrtItem = [[NSMenuItem alloc] initWithTitle:@"Save as SRT"
                                                         action:@selector(saveAsSrt:)
                                                  keyEquivalent:@""];
    [saveSrtItem setTarget:self];
    [appMenu addItem:saveSrtItem];
    [saveSrtItem release];

    NSMenuItem *saveVttItem = [[NSMenuItem alloc] initWithTitle:@"Save as VTT"
                                                         action:@selector(saveAsVtt:)
                                                  keyEquivalent:@""];
    [saveVttItem setTarget:self];
    [appMenu addItem:saveVttItem];
    [saveVttItem release];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Whisper"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];

    // Edit menu
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit"
                                                       action:NULL
                                                keyEquivalent:@""];
    [editItem setSubmenu:editMenu];
    [mainMenu addItem:editItem];

    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copyText:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    // Copy All Text (accessible from menu; use Cmd+A, Cmd+C for quick select-all)
    NSMenuItem *copyAllItem = [[NSMenuItem alloc] initWithTitle:@"Copy All Text"
                                                         action:@selector(copyText:)
                                                  keyEquivalent:@""];
    [copyAllItem setTarget:self];
    [editMenu addItem:copyAllItem];
    [copyAllItem release];

    [NSApp setMainMenu:mainMenu];

    [editItem release];
    [editMenu release];
    [quitItem release];
    [modelMenuItem release];
    [modelMenu release];
    [openItem release];
    [aboutItem release];
    [appMenu release];
    [appItem release];
    [mainMenu release];
}

#pragma mark - Menu Checkmarks

- (void)refreshMenuCheckmarks
{
    NSString *savedModel = [[NSUserDefaults standardUserDefaults] stringForKey:@"LastModel"];
    NSString *savedLang  = [[NSUserDefaults standardUserDefaults] stringForKey:@"LastLanguage"];

    NSMenu *mainMenu = [NSApp mainMenu];
    NSMenuItem *appItem = [[mainMenu itemArray] objectAtIndex:0];
    NSMenu *appMenu = [appItem submenu];

    for (NSMenuItem *item in [appMenu itemArray]) {
        // Model submenu
        if ([[item title] isEqualToString:@"Model"]) {
            for (NSMenuItem *mi in [[item submenu] itemArray]) {
                [mi setState:[[mi representedObject] isEqualToString:savedModel]
                    ? NSOnState : NSOffState];
            }
        }
        // Threads submenu
        if ([[item title] isEqualToString:@"Threads"]) {
            for (NSMenuItem *mi in [[item submenu] itemArray]) {
                [mi setState:([mi tag] == currentThreads) ? NSOnState : NSOffState];
            }
        }
        // Language submenu
        if ([[item title] isEqualToString:@"Language"]) {
            for (NSMenuItem *mi in [[item submenu] itemArray]) {
                [mi setState:[[mi representedObject] isEqualToString:savedLang]
                    ? NSOnState : NSOffState];
            }
        }
    }
}

#pragma mark - UI Creation

- (void)createUI
{
    NSUInteger styleMask = NSTitledWindowMask |
                           NSClosableWindowMask |
                           NSMiniaturizableWindowMask |
                           NSResizableWindowMask;

    mainWindow = [[WhisperFloatingWindow alloc] initWithContentRect:NSMakeRect(0, 0,
                                                       DEFAULT_WINDOW_WIDTH,
                                                       DEFAULT_WINDOW_HEIGHT)
                                                         styleMask:styleMask
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];
    [mainWindow setTitle:@"Whisper Speech-to-Text"];
    [mainWindow setDelegate:self];
    [mainWindow setMinSize:NSMakeSize(CONTENT_MIN_WIDTH, CONTENT_MIN_HEIGHT)];
    [mainWindow setLevel:NSFloatingWindowLevel];

    NSView *contentView = [mainWindow contentView];

    // Recording row
    recordButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [recordButton setTitle:@"Record"];
    [recordButton setTarget:self];
    [recordButton setAction:@selector(recordAudio:)];
    [recordButton setBezelStyle:NSRoundedBezelStyle];
    [recordButton setKeyEquivalentModifierMask:NSAlternateKeyMask];
    [recordButton sizeToFit];
    [contentView addSubview:recordButton];

    stopButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [stopButton setTitle:@"Stop"];
    [stopButton setTarget:self];
    [stopButton setAction:@selector(stopRecording:)];
    [stopButton setBezelStyle:NSRoundedBezelStyle];
    [stopButton setEnabled:NO];
    [stopButton sizeToFit];
    [contentView addSubview:stopButton];

    recordSpinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    [recordSpinner setStyle:NSProgressIndicatorSpinningStyle];
    [recordSpinner setIndeterminate:YES];
    [recordSpinner setControlSize:NSSmallControlSize];
    [recordSpinner sizeToFit];
    [recordSpinner setDisplayedWhenStopped:NO];
    [contentView addSubview:recordSpinner];

    downloadProgress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    [downloadProgress setStyle:NSProgressIndicatorBarStyle];
    [downloadProgress setIndeterminate:NO];
    [downloadProgress setMinValue:0.0];
    [downloadProgress setMaxValue:100.0];
    [downloadProgress setDoubleValue:0.0];
    [downloadProgress setHidden:YES];
    [downloadProgress setDisplayedWhenStopped:NO];
    [contentView addSubview:downloadProgress];

    /*
    translateCheckbox = [[NSButton alloc] initWithFrame:NSZeroRect];
    [translateCheckbox setButtonType:NSSwitchButton];
    [translateCheckbox setTitle:@"Translate to English"];
    [translateCheckbox setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [translateCheckbox sizeToFit];
    [contentView addSubview:translateCheckbox];
    */

    // Progress bar
    progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    [progressBar setStyle:NSProgressIndicatorBarStyle];
    [progressBar setIndeterminate:NO];
    [progressBar setMinValue:0.0];
    [progressBar setMaxValue:100.0];
    [progressBar setDoubleValue:0.0];
    [contentView addSubview:progressBar];

    statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [statusLabel setEditable:NO];
    [statusLabel setBordered:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setBezeled:NO];
    [statusLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [statusLabel setTextColor:[NSColor grayColor]];
    [statusLabel setStringValue:@"Ready"];
    [contentView addSubview:statusLabel];

    // Results text view
    resultScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    [resultScrollView setHasVerticalScroller:YES];
    [resultScrollView setAutoresizesSubviews:YES];
    [resultScrollView setBorderType:NSBezelBorder];
    [resultScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [contentView addSubview:resultScrollView];

    resultTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    [resultTextView setFont:[NSFont userFixedPitchFontOfSize:12]];
    [resultTextView setVerticallyResizable:YES];
    [resultTextView setHorizontallyResizable:NO];
    [resultTextView setAutoresizingMask:NSViewWidthSizable];
    [[resultTextView textContainer] setWidthTracksTextView:YES];
    [resultScrollView setDocumentView:resultTextView];
    // scroll view now owns resultTextView; we keep a zero-ing ivar so it
    // must NOT be released here (non-ARC: the scroll view retains it).
    // (We deliberately do NOT send extra release to keep the ivar valid.)

    copyTextButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [copyTextButton setTitle:@"Copy to Clipboard"];
    [copyTextButton setTarget:self];
    [copyTextButton setAction:@selector(copyText:)];
    [copyTextButton setBezelStyle:NSRoundedBezelStyle];
    [copyTextButton sizeToFit];
    [copyTextButton setEnabled:NO];
    [contentView addSubview:copyTextButton];



    showTimestampsCheckbox = [[NSButton alloc] initWithFrame:NSZeroRect];
    [showTimestampsCheckbox setButtonType:NSSwitchButton];
    [showTimestampsCheckbox setTitle:@"Show Timestamps"];
    [showTimestampsCheckbox setTarget:self];
    [showTimestampsCheckbox setAction:@selector(timestampsToggled:)];
    [showTimestampsCheckbox setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [showTimestampsCheckbox sizeToFit];
    [showTimestampsCheckbox setState:NSOffState];
    [contentView addSubview:showTimestampsCheckbox];

    [self layoutSubviews];
}

#pragma mark - Layout

- (void)layoutSubviews
{
    NSView *cv = [mainWindow contentView];
    NSRect bounds = [cv bounds];

    CGFloat mx = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat mt = METRICS_CONTENT_TOP_MARGIN;
    CGFloat mb = METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat w  = bounds.size.width - mx * 2;
    CGFloat y  = bounds.size.height - mt;

    CGFloat bh  = METRICS_BUTTON_HEIGHT;
    CGFloat s8  = METRICS_SPACE_8;
    CGFloat s16 = METRICS_SPACE_16;

    // ---- Row 1: Recording + file open ----
    NSSize recSize  = [recordButton frame].size;
    NSSize stopSize = [stopButton frame].size;

    [recordButton setFrame:NSMakeRect(mx, y - bh, recSize.width, bh)];
    [stopButton setFrame:NSMakeRect(mx + recSize.width + s8, y - bh,
                                    stopSize.width, bh)];

    [statusLabel setAlignment:NSRightTextAlignment];

    CGFloat spinnerW = [recordSpinner frame].size.width;
    CGFloat afterStop = mx + recSize.width + s8 + stopSize.width + s8;
    [recordSpinner setFrame:NSMakeRect(afterStop, y - bh + (bh - spinnerW) / 2,
                                        spinnerW, spinnerW)];
    CGFloat statusX2 = afterStop + spinnerW + s8;
    CGFloat statusW2 = w - (statusX2 - mx);
    if (statusW2 < 60) statusW2 = 60;
    [statusLabel setFrame:NSMakeRect(statusX2, y - bh, statusW2, bh)];
    y -= bh + s16;

    // ---- Row 4: Settings ----
    y -= bh + s16;

    // ---- Row 5: Progress bar ----
    [progressBar setFrame:NSMakeRect(mx, y, w, bh)];
    y -= bh + s8;

    // ---- Bottom row: checkboxes (left) + action buttons (right) ----
    NSSize copySz = [copyTextButton frame].size;
    NSSize tsSz   = [showTimestampsCheckbox frame].size;
    CGFloat bottomRowY = mb + s8;
    CGFloat textY      = bottomRowY + bh + s8;
    [resultScrollView setFrame:NSMakeRect(mx, textY, w, y - textY)];
    [[resultTextView textContainer] setContainerSize:
        NSMakeSize([resultScrollView contentSize].width, FLT_MAX)];
    [showTimestampsCheckbox setFrame:NSMakeRect(mx, bottomRowY, tsSz.width, bh)];
    [copyTextButton setFrame:NSMakeRect(mx + w - copySz.width, bottomRowY,
                                        copySz.width, bh)];

    // Export buttons removed — now in Whisper menu
}

- (void)windowDidResize:(NSNotification *)notification
{
    [self layoutSubviews];
}

#pragma mark - Window

#pragma mark - Auto-type

- (NSString *)plainTextFromSegments
{
    NSMutableString *result = [NSMutableString string];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSDictionary *seg in segments) {
        NSString *txt = [seg objectForKey:@"text"];
        if (!txt) continue;
        // Strip leading whitespace whisper often prepends
        NSUInteger i = 0;
        while (i < [txt length] && [ws characterIsMember:[txt characterAtIndex:i]])
            i++;
        if (i < [txt length]) {
            if ([result length] > 0) [result appendString:@" "];
            [result appendString:[txt substringFromIndex:i]];
        }
    }
    return result;
}

- (void)buildWhisperEngineWithScript:(NSString *)scriptPath
{
    buildProgressPct = 0;
    buildThreadRunning = YES;

    CGFloat ww = 380, lx = 20, lw = ww - 2*lx;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, ww, 48)
                                                 styleMask:NSTitledWindowMask
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    [win setTitle:@"Whisper"];
    [win center];

    NSProgressIndicator *prog = [[NSProgressIndicator alloc]
      initWithFrame:NSMakeRect(lx, 12, lw, 20)];
    [prog setStyle:NSProgressIndicatorBarStyle];
    [prog setIndeterminate:NO];
    [prog setMinValue:0]; [prog setMaxValue:100]; [prog setDoubleValue:0];
    [[win contentView] addSubview:prog];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(lx, 44, lw, 18)];
    [label setStringValue:@"Preparing for first run..."];
    [label setEditable:NO]; [label setSelectable:NO];
    [label setBordered:NO]; [label setBezeled:NO]; [label setDrawsBackground:NO];
    [[win contentView] addSubview:label];

    [win makeKeyAndOrderFront:self];
    objc_setAssociatedObject(self, "_buildWin", win, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, "_buildProg", prog, OBJC_ASSOCIATION_RETAIN);

    // Polling timer 2x/sec updates the progress bar from the shared ivar
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                   selector:@selector(buildPollProgress:)
                                   userInfo:nil repeats:YES];

    [self performSelectorInBackground:@selector(buildThread:)
                           withObject:scriptPath];
}

- (void)buildPollProgress:(NSTimer *)t
{
    if (!buildThreadRunning) { [t invalidate]; return; }
    NSProgressIndicator *p = objc_getAssociatedObject(self, "_buildProg");
    if (p) {
        [p setDoubleValue:(double)buildProgressPct];
        [p setNeedsDisplay:YES];
    }
}

- (void)buildThread:(NSString *)scriptPath
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *cmd = [NSString stringWithFormat:@"sudo -A -E sh '%@' 2>&1 | awk '{print; fflush()}'", scriptPath];
    FILE *fp = popen([cmd UTF8String], "r");
    if (!fp) {
        buildThreadRunning = NO;
        [self performSelectorOnMainThread:@selector(buildDoneWithStatus:)
                               withObject:[NSNumber numberWithInt:-1]
                            waitUntilDone:NO];
        [pool release];
        return;
    }
    char line[4096];
    while (fgets(line, sizeof(line), fp)) {
        fprintf(stderr, "%s", line);
        char *p = line;
        while ((p = strstr(p, "["))) {
            p++;
            int pct;
            if (sscanf(p, " %d%%", &pct) >= 1) {
                buildProgressPct = pct;  // shared ivar, read by poll timer
                break;
            }
        }
    }
    int status = pclose(fp);
    buildThreadRunning = NO;
    [self performSelectorOnMainThread:@selector(buildDoneWithStatus:)
                           withObject:[NSNumber numberWithInt:status]
                        waitUntilDone:NO];
    [pool release];
}

- (void)buildDoneWithStatus:(NSNumber *)statusObj
{
    int status = [statusObj intValue];

    NSWindow *w = objc_getAssociatedObject(self, "_buildWin");
    [w close];
    [w release];
    objc_setAssociatedObject(self, "_buildWin", nil, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, "_buildProg", nil, OBJC_ASSOCIATION_RETAIN);

    // Re-dlopen libwhisper since it was just installed
    wdlopen_close();
    wdlopen_init();

    if (status != 0 || !wdlopen_init()) {
        NSAlert *a = [[NSAlert alloc] init];
        [a setMessageText:@"Build failed"];
        [a setInformativeText:@"whisper.cpp could not be built. Check the terminal for details."];
        [a addButtonWithTitle:@"OK"];
        [a runModal];
        [a release];
    }
    [self finishStartup];
}

- (void)finishStartup
{
    // Register pasteboard types so GSServicesManager shows our
    // "Dictate Text" service (it returns NSStringPboardType, no input)
    [NSApp registerServicesMenuSendTypes:@[]
                             returnTypes:@[NSStringPboardType]];
    // Register the "Dictate Text" GNUstep service
    [NSApp setServicesProvider:self];

    [mainWindow center];
    [mainWindow makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - GNUstep Service: Dictate Text

// Returns the default capture device path (ALSA "plughw:N,M" or OSS "/dev/dspN")
// or nil if no input backend is available.
- (NSString *)defaultCaptureDevice
{
    id<SoundBackend> snd = nil;
    NSString *devPath = nil;

#if defined(__FreeBSD__) || defined(__DragonFly__) || defined(__OpenBSD__) || defined(__NetBSD__)
    OSSBackend *oss = [[OSSBackend alloc] init];
    if ([oss isAvailable]) {
        snd = oss;
        AudioDevice *dev = [oss defaultInputDevice];
        if (dev)
            devPath = [NSString stringWithFormat:@"/dev/dsp%d", [dev cardIndex]];
    } else {
        [oss release]; oss = nil;
    }
#endif
    if (!snd) {
        ALSABackend *alsa = [[ALSABackend alloc] init];
        if ([alsa isAvailable]) {
            snd = alsa;
            AudioDevice *dev = [alsa defaultInputDevice];
            if (dev)
                devPath = [NSString stringWithFormat:@"plughw:%d,%d",
                                    [dev cardIndex], [dev deviceIndex]];
        } else {
            [alsa release]; alsa = nil;
        }
    }
    [snd release];
    return devPath;
}

// Service entry point. Called via DO from any application's Services menu.
// Records speech until silence, transcribes it, returns text on pboard.
- (void)dictate:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{
    if (!wdlopen_init()) {
        if (error) *error = @"whisper.cpp library not available";
        return;
    }
    if (!whisperCtx) {
        NSString *mn = [[NSUserDefaults standardUserDefaults] stringForKey:@"LastModel"];
        NSString *mp  = mn ? [self modelPathForName:mn] : nil;
        if (mp && [[NSFileManager defaultManager] fileExistsAtPath:mp])
            [self loadModel:mp];
        if (!whisperCtx) {
            if (error) *error = @"No model loaded";
            return;
        }
    }

    // Capture on default device
    NSString *capDev = [self defaultCaptureDevice];
    void *cap = wcapture_start(16000, [capDev UTF8String]);
    if (!cap) {
        if (error) *error = @"No microphone found";
        return;
    }

    // Record until silence-after-speech, no-speech timeout, or hard cap
    NSDate *started = [NSDate date];
    BOOL heardSpeech = NO;
    int silentChecks = 0;
    int lastN = 0;
    static const float kSpeechThresh = 0.02f;

    while (1) {
        usleep(500000);   // check every half second

        float *s = NULL;
        int n = wcapture_snapshot(cap, &s);
        if (n > lastN && s) {
            float peak = 0.0f;
            for (int i = lastN; i < n; i++) {
                float a = s[i] < 0 ? -s[i] : s[i];
                if (a > peak) peak = a;
            }
            free(s);
            if (peak >= kSpeechThresh) { heardSpeech = YES; silentChecks = 0; }
            else if (heardSpeech)      silentChecks++;
        }
        lastN = n;

        NSTimeInterval elapsed = -[started timeIntervalSinceNow];
        if (heardSpeech && silentChecks >= 4) break;         // ~2 s of silence
        if (!heardSpeech && elapsed > 10.0) break;           // nothing said
        if (elapsed > 60.0) break;                           // hard cap
    }

    WCaptureData *cd = wcapture_stop(cap);
    if (!cd || cd->n_samples == 0 || !heardSpeech) {
        wcapture_free_data(cd);
        if (error) *error = heardSpeech ? @"Transcription failed" : @"No speech detected";
        return;
    }

    // Transcribe synchronously (no streaming callbacks)
    struct whisper_full_params wparams =
        wdlopen_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.n_threads = currentThreads;
    wparams.language = "en";
    wparams.detect_language = false;
    wparams.no_timestamps = true;
    wparams.print_progress = false;
    wparams.print_realtime = false;
    wparams.print_special = false;
    wparams.new_segment_callback = NULL;
    wparams.progress_callback = NULL;

    if (vocabularyPrompt)
        wparams.initial_prompt = [vocabularyPrompt UTF8String];

    int ret = wdlopen_full(whisperCtx, wparams, cd->samples, cd->n_samples);
    wcapture_free_data(cd);
    if (ret != 0) {
        if (error) *error = @"Transcription failed";
        return;
    }

    NSMutableString *text = [NSMutableString string];
    int totalSegs = wdlopen_full_n_segments(whisperCtx);
    for (int i = 0; i < totalSegs; i++) {
        const char *st = wdlopen_full_get_segment_text(whisperCtx, i);
        if (st) [text appendString:[NSString stringWithUTF8String:st]];
    }
    text = [[text stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceAndNewlineCharacterSet]] mutableCopy];

    if ([text length] == 0) {
        if (error) *error = @"No speech detected";
        return;
    }

    // Return the transcribed text to the requesting application
    [pboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [pboard setString:text forType:NSStringPboardType];
}

- (void)syncTypedText
{
    NSString *desired = [self plainTextFromSegments];
    if (!desired) desired = @"";
    if (!typedText) typedText = [@"" retain];

    if ([typedText isEqualToString:desired]) return;

    NSUInteger oldLen = [typedText length];
    NSUInteger newLen = [desired length];
    NSUInteger common = 0;
    NSUInteger minLen = oldLen < newLen ? oldLen : newLen;
    for (NSUInteger i = 0; i < minLen; i++) {
        if ([typedText characterAtIndex:i] == [desired characterAtIndex:i])
            common++;
        else
            break;
    }

    if (common < oldLen)
        [self typeBackspaces:(int)(oldLen - common)];

    if (common < newLen) {
        NSString *toType = [desired substringFromIndex:common];
        [self typeTextToApp:toType];
    }

    [typedText release];
    typedText = [desired retain];
}

- (void)typeBackspaces:(int)count
{
    if (count <= 0) return;
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xdoPath];
    NSString *winArg = [NSString stringWithFormat:@"%lu", targetWindowID];
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"key", @"--clearmodifiers", @"--window", winArg, nil];
    for (int i = 0; i < count; i++)
        [args addObject:@"BackSpace"];
    [task setArguments:args];
    [task launch];
    [task waitUntilExit];
    [task release];
}

- (void)typeTextToApp:(NSString *)text
{
    if ([text length] == 0) return;
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xdoPath];
    NSString *winArg = [NSString stringWithFormat:@"%lu", targetWindowID];
    [task setArguments:[NSArray arrayWithObjects:
        @"type", @"--clearmodifiers", @"--delay", @"12",
        @"--window", winArg, text, nil]];
    [task launch];
    [task waitUntilExit];
    [task release];
}

@end
