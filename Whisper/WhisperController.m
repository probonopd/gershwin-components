/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WhisperController.h"
#import "AppearanceMetrics.h"
#import "WAudioLoader.h"
#import "WCapture.h"

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
#import <Foundation/NSTimer.h>
#import <Foundation/NSTask.h>
#import <Foundation/NSUserDefaults.h>
#import <Foundation/NSFileHandle.h>

#import <whisper.h>

#define DEFAULT_WINDOW_WIDTH  720.0
#define DEFAULT_WINDOW_HEIGHT 520.0
#define CONTENT_MIN_WIDTH     620.0
#define CONTENT_MIN_HEIGHT    400.0

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
    int total = whisper_full_n_segments(ctx);

    NSMutableArray *newSegs = [NSMutableArray array];
    NSMutableString *text = [NSMutableString string];

    for (int i = total - n_new; i < total; i++) {
        const char *seg_text = whisper_full_get_segment_text(ctx, i);
        if (!seg_text) continue;

        int64_t t0 = whisper_full_get_segment_t0(ctx, i);
        int64_t t1 = whisper_full_get_segment_t1(ctx, i);

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
    [super dealloc];
}

#pragma mark - App Delegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [self createUI];
    [self createMenu];

    // Restore last selected model
    NSString *savedModel = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"LastModel"];
    if (savedModel) {
        for (NSMenuItem *item in [modelPopup itemArray]) {
            if ([[item representedObject] isEqualToString:savedModel]) {
                [modelPopup selectItem:item];
                break;
            }
        }
    }

    // Restore last selected language
    NSString *savedLang = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"LastLanguage"];
    if (savedLang) {
        for (NSMenuItem *item in [languagePopup itemArray]) {
            if ([[item representedObject] isEqualToString:savedLang]) {
                [languagePopup selectItem:item];
                break;
            }
        }
    }
    [currentLangCode release];
    currentLangCode = [[[languagePopup selectedItem] representedObject] copy];

    [self updateUIForState];

    [mainWindow center];
    [mainWindow makeKeyAndOrderFront:self];
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
    if (filePathLabel) {
        [filePathLabel setStringValue:filename];
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

    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        NSLog(@"loadModel: model file not found at %@", modelPath);
        [self setState:WhisperStateError];
        [statusLabel setStringValue:@"Model file not found"];
        return;
    }

    [self setState:WhisperStateLoadingModel];
    [statusLabel setStringValue:@"Loading model..."];

    // Try GPU first, fall back to CPU
    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = true;

    NSLog(@"loadModel: trying GPU (%@)", modelPath);
    whisperCtx = whisper_init_from_file_with_params(
        [modelPath UTF8String], cparams);

    if (!whisperCtx) {
        NSLog(@"loadModel: GPU init failed, retrying with CPU");
        cparams.use_gpu = false;
        cparams.flash_attn = false;
        whisperCtx = whisper_init_from_file_with_params(
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
                    [[modelPopup selectedItem] representedObject]];
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
        whisper_free(whisperCtx);
        whisperCtx = NULL;
    }
}

- (IBAction)downloadModel:(id)sender
{
    if (downloadTask && [downloadTask isRunning]) {
        [downloadTask terminate];
        [downloadTask release];
        downloadTask = nil;
        [downloadProgress setDoubleValue:0.0];
        [downloadProgress setHidden:YES];
        [downloadData release];
        downloadData = nil;
        [downloadFH release];
        downloadFH = nil;
        [downloadButton setTitle:@"Download"];
        [self setState:WhisperStateIdle];
        return;
    }

    NSString *selectedName = [[modelPopup selectedItem] representedObject];
    if (!selectedName) return;

    if ([self modelExists:selectedName]) {
        NSString *urlStr = [NSString stringWithFormat:
            @"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/%@",
            selectedName];
        NSLog(@"downloadModel: '%@' already exists at %@",
              selectedName, [self modelPathForName:selectedName]);
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Model already exists"];
        [alert setInformativeText:[NSString stringWithFormat:
            @"%@ is already downloaded.\n\n%@", selectedName, urlStr]];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
        return;
    }

    [self downloadModelWithName:selectedName];
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
    [downloadButton setTitle:@"Cancel"];
    [statusLabel setStringValue:[NSString stringWithFormat:
        @"Downloading %@", name]];
    [self setState:WhisperStateLoadingModel];

    [downloadingModel release];
    downloadingModel = [name retain];

    [downloadData release];
    downloadData = [[NSMutableData alloc] init];

    NSPipe *stderrPipe = [NSPipe pipe];
    downloadFH = [[stderrPipe fileHandleForReading] retain];

    downloadTask = [[NSTask alloc] init];
    [downloadTask setLaunchPath:@"/usr/bin/curl"];
    [downloadTask setArguments:[NSArray arrayWithObjects:
        @"-L", @"-o", destPath, @"-C", @"-", @"--progress-bar", urlStr, nil]];
    [downloadTask setStandardError:stderrPipe];
    [downloadTask setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(downloadFinished:)
               name:NSTaskDidTerminateNotification
             object:downloadTask];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(downloadStderrData:)
               name:NSFileHandleReadCompletionNotification
             object:downloadFH];

    [downloadFH readInBackgroundAndNotify];
    [downloadTask launch];
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

- (void)downloadStderrData:(NSNotification *)notif
{
    NSData *data = [[notif userInfo] objectForKey:NSFileHandleNotificationDataItem];
    NSFileHandle *fh = [notif object];

    if ([data length] > 0) {
        [downloadData appendData:data];

        // Find the last percentage in the accumulated buffer
        const char *bytes = [downloadData bytes];
        NSUInteger len = [downloadData length];
        NSUInteger i;

        // Work backwards from the end, looking for a percentage pattern
        for (i = len; i > 0; i--) {
            if (bytes[i - 1] == '%') {
                // Found a '%', now find the start of the number
                NSUInteger start = i - 1;
                while (start > 0) {
                    start--;
                    char c = bytes[start];
                    if (!(c == ' ' || c == '\r' || c == '\n' ||
                          c == '.' || (c >= '0' && c <= '9'))) {
                        start++;
                        break;
                    }
                }
                if (start < i) {
                    // Extract the number
                    char buf[16];
                    NSUInteger n = i - start;
                    if (n > 0 && n < sizeof(buf)) {
                        memcpy(buf, bytes + start, n);
                        buf[n] = '\0';
                        // Trim leading spaces
                        char *p = buf;
                        while (*p == ' ') p++;
                        if (*p) {
                            double pct = atof(p);
                            [self performSelectorOnMainThread:@selector(downloadProgressUpdated:)
                                                   withObject:[NSNumber numberWithDouble:pct]
                                                waitUntilDone:NO];
                        }
                    }
                }
                break;
            }
        }

        // Trim buffer: keep only the last ~200 bytes to avoid unbounded growth
        if (len > 200) {
            NSRange tail = NSMakeRange(len - 200, 200);
            [downloadData setData:[downloadData subdataWithRange:tail]];
        }
    }

    [fh readInBackgroundAndNotify];
}

- (void)downloadProgressUpdated:(NSNumber *)pct
{
    double v = [pct doubleValue];
    [downloadProgress setDoubleValue:v];
    [downloadProgress displayIfNeeded];
    [statusLabel setStringValue:[NSString stringWithFormat:
        @"Downloading %@ — %.0f%%", downloadingModel, v]];
}

- (void)downloadFinished:(NSNotification *)notif
{
    int status = [[notif object] terminationStatus];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:[notif object]];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSFileHandleReadCompletionNotification
                                                  object:downloadFH];

    [downloadProgress setDoubleValue:100.0];
    [downloadProgress setHidden:YES];
    [downloadButton setTitle:@"Download"];
    [downloadData release];
    downloadData = nil;
    [downloadFH release];
    downloadFH = nil;
    [downloadTask release];
    downloadTask = nil;

    if (status == 0) {
        NSLog(@"downloadFinished: successfully downloaded %@", downloadingModel);
        [statusLabel setStringValue:[NSString stringWithFormat:
            @"Downloaded %@", downloadingModel]];
        // Refresh model popup
        NSString *selected = [[modelPopup selectedItem] representedObject];
        [modelPopup removeAllItems];
        for (int i = 0; modelNames[i] != NULL; i++) {
            NSString *label = [NSString stringWithUTF8String:modelSizes[i]];
            NSString *name = [NSString stringWithUTF8String:modelNames[i]];
            [modelPopup addItemWithTitle:label];
            [[modelPopup lastItem] setRepresentedObject:name];
        }
        // Restore selection
        for (NSMenuItem *item in [modelPopup itemArray]) {
            if ([[item representedObject] isEqualToString:selected]) {
                [modelPopup selectItem:item];
                break;
            }
        }
        // Persist restored selection
        if (selected) {
            [[NSUserDefaults standardUserDefaults] setObject:selected
                                                      forKey:@"LastModel"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    } else {
        NSLog(@"downloadFinished: FAILED (status=%d) for %@", status, downloadingModel);
        [statusLabel setStringValue:[NSString stringWithFormat:
            @"Download failed for %@", downloadingModel]];
        [self setState:WhisperStateError];
    }

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
        NSString *selectedName = [[modelPopup selectedItem] representedObject];
        if (!selectedName) {
            [statusLabel setStringValue:@"Please select a model"];
            return;
        }
        NSString *modelPath = [self modelPathForName:selectedName];
        if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
            [statusLabel setStringValue:@"Model not downloaded. Click Download first."];
            return;
        }
        [self loadModel:modelPath];
        if (!whisperCtx) return;
    }

    [[self segments] removeAllObjects];
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

    struct whisper_full_params wparams = whisper_full_default_params(
        WHISPER_SAMPLING_GREEDY);

    wparams.n_threads = [threadsField intValue];
    if (wparams.n_threads < 1) wparams.n_threads = 1;
    if (wparams.n_threads > 32) wparams.n_threads = 32;

    NSString *langCode = currentLangCode;
    if (langCode && ![langCode isEqualToString:@"auto"]) {
        wparams.language = [langCode UTF8String];
        wparams.detect_language = false;
    } else {
        wparams.detect_language = false;
        whisper_pcm_to_mel(whisperCtx, samples, n_samples, wparams.n_threads);
        int lang_id = whisper_lang_auto_detect(whisperCtx, 0, wparams.n_threads, NULL);
        if (lang_id >= 0) {
            wparams.language = whisper_lang_str(lang_id);
        } else {
            wparams.language = "en";
        }
    }

    wparams.translate = [translateCheckbox state] == NSOnState ? true : false;
    wparams.no_timestamps = false;
    wparams.print_progress = false;
    wparams.print_realtime = false;
    wparams.print_special = false;

    wparams.progress_callback = whisper_progress_cb;
    wparams.progress_callback_user_data = self;

    int ret = whisper_full(whisperCtx, wparams, samples, n_samples);

    free(samples);

    if (ret != 0) {
        [self performSelectorOnMainThread:@selector(transcriptionFailed:)
                               withObject:@"Transcription failed"
                            waitUntilDone:NO];
        [pool release];
        return;
    }

    int n_segments = whisper_full_n_segments(whisperCtx);
    NSMutableString *result = [NSMutableString string];

    for (int i = 0; i < n_segments; i++) {
        const char *text = whisper_full_get_segment_text(whisperCtx, i);
        int64_t t0 = whisper_full_get_segment_t0(whisperCtx, i);
        int64_t t1 = whisper_full_get_segment_t1(whisperCtx, i);

        NSString *segmentText = [NSString stringWithUTF8String:text];
        if (!segmentText) continue;

        NSDictionary *seg = [NSDictionary dictionaryWithObjectsAndKeys:
            segmentText, @"text",
            [NSNumber numberWithLongLong:t0], @"t0",
            [NSNumber numberWithLongLong:t1], @"t1",
            nil];
        [segments addObject:seg];

        [result appendFormat:@"[%@ --> %@] %@\n",
            [self formatTimestamp:t0],
            [self formatTimestamp:t1],
            segmentText];
    }

    [self performSelectorOnMainThread:@selector(transcriptionFinished:)
                           withObject:result
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

    if (resultTextView) {
        [resultTextView setString:result];
    }
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
    } else {
        [recordSpinner stopAnimation:nil];
    }

    // Check whether a model file is available (even if not yet loaded)
    BOOL modelAvailable = NO;
    NSString *selModel = [[modelPopup selectedItem] representedObject];
    if (selModel) {
        NSString *mp = [self modelPathForName:selModel];
        if (mp) modelAvailable = [[NSFileManager defaultManager] fileExistsAtPath:mp];
    }
    [transcribeButton setEnabled:(!isWorking && !isRecording &&
                                  (currentFilePath != nil) &&
                                  modelAvailable)];
    [openButton setEnabled:(!isWorking && !isRecording)];
    [modelPopup setEnabled:(!isWorking && !isRecording)];
    [languagePopup setEnabled:(!isWorking && !isRecording)];
    [translateCheckbox setEnabled:(!isWorking && !isRecording)];
    [threadsField setEnabled:(!isWorking && !isRecording)];
    [threadsStepper setEnabled:(!isWorking && !isRecording)];
    [recordButton setEnabled:(!isRecording && !isWorking)];
    [stopButton setEnabled:isRecording];

    BOOL hasResults = [segments count] > 0;
    [saveTxtButton setEnabled:hasResults];
    [saveSrtButton setEnabled:hasResults];
    [saveVttButton setEnabled:hasResults];

    if (state == WhisperStateTranscribing) {
        [transcribeButton setTitle:@"Transcribing..."];
    } else {
        [transcribeButton setTitle:@"Transcribe"];
    }
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
    captureHandle = wcapture_start(sr);
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
        NSString *selectedName = [[modelPopup selectedItem] representedObject];
        if (!selectedName) {
            NSLog(@"recordAudio: no model selected, canceling capture");
            wcapture_cancel(captureHandle);
            captureHandle = NULL;
            [statusLabel setStringValue:@"Please select a model"];
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
    [self setState:WhisperStateRecording];
    recordStartTime = [NSDate timeIntervalSinceReferenceDate];
    lastSegmentCount = 0;
    [recordStatusLabel setStringValue:@"Recording 00:00"];

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
    [recordStatusLabel setStringValue:@"Recording stopped"];

    // Save as current file path for later reuse
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *tmpPath = [tmpDir stringByAppendingPathComponent:@"whisper_recording.wav"];
    [self setCurrentFilePath:tmpPath];
    [filePathLabel setStringValue:@"[Microphone]"];

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
    [recordStatusLabel setStringValue:[NSString stringWithFormat:
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

    struct whisper_full_params wparams = whisper_full_default_params(
        WHISPER_SAMPLING_GREEDY);

    wparams.n_threads = [threadsField intValue];
    if (wparams.n_threads < 1) wparams.n_threads = 1;
    if (wparams.n_threads > 32) wparams.n_threads = 32;

    // Read language from ivar (set on main thread, safe for background read)
    NSString *langCode = currentLangCode;
    if (langCode && ![langCode isEqualToString:@"auto"]) {
        wparams.language = [langCode UTF8String];
        wparams.detect_language = false;
        NSLog(@"transcribeStreamingChunk: language=%@", langCode);
    } else {
        wparams.detect_language = false;
        whisper_pcm_to_mel(whisperCtx, samples, n, wparams.n_threads);
        int lang_id = whisper_lang_auto_detect(whisperCtx, 0, wparams.n_threads, NULL);
        if (lang_id >= 0) {
            wparams.language = whisper_lang_str(lang_id);
        } else {
            wparams.language = "en";
        }
        NSLog(@"transcribeStreamingChunk: auto-detected language=%s", wparams.language);
    }

    wparams.translate = [translateCheckbox state] == NSOnState ? true : false;
    wparams.no_timestamps = false;
    wparams.print_progress = false;
    wparams.print_realtime = false;
    wparams.print_special = false;
    wparams.new_segment_callback = whisper_new_segment_cb;
    wparams.new_segment_callback_user_data = self;

    NSLog(@"transcribeStreamingChunk: calling whisper_full (segments appear via callback)...");
    int ret = whisper_full(whisperCtx, wparams, samples, n);
    NSLog(@"transcribeStreamingChunk: whisper_full returned %d", ret);

    // Update segment count from the final result
    lastSegmentCount = whisper_full_n_segments(whisperCtx);
    NSLog(@"transcribeStreamingChunk: done, total segments=%d", lastSegmentCount);

    isTranscribing = NO;
    [pool release];
}

- (void)appendStreamingResult:(NSDictionary *)result
{
    NSArray *newSegs = [result objectForKey:@"segments"];

    NSLog(@"appendStreamingResult: %lu new segments",
          (unsigned long)[newSegs count]);

    // Remove existing segments that overlap in time with incoming
    // segments, then add the new ones.  Whisper may shift timestamps
    // on each pass, so exact-t0 matching causes duplicates.
    for (NSDictionary *seg in newSegs) {
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

    // Rebuild the entire text view from the cleaned-up segments array.
    if (resultTextView) {
        NSMutableString *full = [NSMutableString string];
        for (NSDictionary *seg in segments) {
            int64_t t0 = [[seg objectForKey:@"t0"] longLongValue];
            int64_t t1 = [[seg objectForKey:@"t1"] longLongValue];
            NSString *txt = [seg objectForKey:@"text"];
            [full appendFormat:@"[%@ --> %@] %@\n",
                [self formatTimestamp:t0],
                [self formatTimestamp:t1],
                txt];
        }
        [resultTextView setString:full];
        [resultTextView scrollRangeToVisible:
            NSMakeRange([full length], 0)];
        [resultTextView displayIfNeeded];
        NSLog(@"appendStreamingResult: rebuilt text view (%lu segments, %lu chars)",
              (unsigned long)[segments count], (unsigned long)[full length]);
    }
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
        [filePathLabel setStringValue:path];
        [self setState:WhisperStateIdle];
    }
}

- (IBAction)modelChanged:(id)sender
{
    NSString *name = [[modelPopup selectedItem] representedObject];
    if (name) {
        [[NSUserDefaults standardUserDefaults] setObject:name forKey:@"LastModel"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"modelChanged: saved '%@' as last model", name);
    }
}

- (IBAction)languageChanged:(id)sender
{
    NSString *code = [[languagePopup selectedItem] representedObject];
    if (code) {
        [currentLangCode release];
        currentLangCode = [code copy];
        [[NSUserDefaults standardUserDefaults] setObject:code
                                                  forKey:@"LastLanguage"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"languageChanged: saved '%@'", code);
    }
}

- (IBAction)threadsChanged:(id)sender
{
    int val = [threadsStepper intValue];
    [threadsField setIntValue:val];
}

- (IBAction)saveAsTxt:(id)sender
{
    [self saveTranscriptionWithFormat:@"txt"];
}

- (IBAction)saveAsSrt:(id)sender
{
    [self saveTranscriptionWithFormat:@"srt"];
}

- (IBAction)saveAsVtt:(id)sender
{
    [self saveTranscriptionWithFormat:@"vtt"];
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

    NSMenu *appMenu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Whisper"
                                                     action:nil
                                              keyEquivalent:@""];
    [appItem setSubmenu:appMenu];
    [mainMenu addItem:appItem];

    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About Whisper"
                                                       action:@selector(orderFrontStandardAboutPanel:)
                                                keyEquivalent:@""];
    [aboutItem setTarget:NSApp];
    [appMenu addItem:aboutItem];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Whisper"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [quitItem setTarget:NSApp];
    [appMenu addItem:quitItem];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit"
                                                      action:nil
                                               keyEquivalent:@""];
    [editItem setSubmenu:editMenu];
    [mainMenu addItem:editItem];

    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    [NSApp setMainMenu:mainMenu];

    [editItem release];
    [editMenu release];
    [quitItem release];
    [aboutItem release];
    [appMenu release];
    [appItem release];
    [mainMenu release];
}

#pragma mark - UI Creation

- (void)createUI
{
    NSUInteger styleMask = NSTitledWindowMask |
                           NSClosableWindowMask |
                           NSMiniaturizableWindowMask |
                           NSResizableWindowMask;

    mainWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0,
                                                DEFAULT_WINDOW_WIDTH,
                                                DEFAULT_WINDOW_HEIGHT)
                                             styleMask:styleMask
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    [mainWindow setTitle:@"Whisper Speech-to-Text"];
    [mainWindow setDelegate:self];
    [mainWindow setMinSize:NSMakeSize(CONTENT_MIN_WIDTH, CONTENT_MIN_HEIGHT)];

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

    recordStatusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [recordStatusLabel setEditable:NO];
    [recordStatusLabel setBordered:NO];
    [recordStatusLabel setDrawsBackground:NO];
    [recordStatusLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [recordStatusLabel setTextColor:[NSColor grayColor]];
    [recordStatusLabel setStringValue:@""];
    [contentView addSubview:recordStatusLabel];

    recordSpinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    [recordSpinner setStyle:NSProgressIndicatorSpinningStyle];
    [recordSpinner setIndeterminate:YES];
    [recordSpinner setControlSize:NSSmallControlSize];
    [recordSpinner sizeToFit];
    [recordSpinner setDisplayedWhenStopped:NO];
    [contentView addSubview:recordSpinner];

    openButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [openButton setTitle:@"Open File..."];
    [openButton setTarget:self];
    [openButton setAction:@selector(openFile:)];
    [openButton setBezelStyle:NSRoundedBezelStyle];
    [openButton sizeToFit];
    [contentView addSubview:openButton];

    filePathLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [filePathLabel setEditable:NO];
    [filePathLabel setSelectable:YES];
    [filePathLabel setBordered:NO];
    [filePathLabel setDrawsBackground:NO];
    [filePathLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [filePathLabel setTextColor:[NSColor grayColor]];
    [filePathLabel setStringValue:@"No file selected"];
    [contentView addSubview:filePathLabel];

    // Model row
    modelLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [modelLabel setEditable:NO];
    [modelLabel setBordered:NO];
    [modelLabel setDrawsBackground:NO];
    [modelLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [modelLabel setStringValue:@"Model:"];
    [modelLabel sizeToFit];
    [contentView addSubview:modelLabel];
    [modelLabel release];

    modelPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect];
    [modelPopup removeAllItems];
    for (int i = 0; modelNames[i] != NULL; i++) {
        NSString *label = [NSString stringWithUTF8String:modelSizes[i]];
        NSString *name = [NSString stringWithUTF8String:modelNames[i]];
        [modelPopup addItemWithTitle:label];
        [[modelPopup lastItem] setRepresentedObject:name];
    }
    [modelPopup setTarget:self];
    [modelPopup setAction:@selector(modelChanged:)];
    [contentView addSubview:modelPopup];

    downloadButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [downloadButton setTitle:@"Download"];
    [downloadButton setTarget:self];
    [downloadButton setAction:@selector(downloadModel:)];
    [downloadButton setBezelStyle:NSRoundedBezelStyle];
    [downloadButton sizeToFit];
    [contentView addSubview:downloadButton];

    downloadProgress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    [downloadProgress setStyle:NSProgressIndicatorBarStyle];
    [downloadProgress setIndeterminate:NO];
    [downloadProgress setMinValue:0.0];
    [downloadProgress setMaxValue:100.0];
    [downloadProgress setDoubleValue:0.0];
    [downloadProgress setHidden:YES];
    [downloadProgress setDisplayedWhenStopped:NO];
    [contentView addSubview:downloadProgress];

    // Settings row
    langLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [langLabel setEditable:NO];
    [langLabel setBordered:NO];
    [langLabel setDrawsBackground:NO];
    [langLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [langLabel setStringValue:@"Language:"];
    [langLabel sizeToFit];
    [contentView addSubview:langLabel];
    [langLabel release];

    languagePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect];
    [languagePopup removeAllItems];
    for (int i = 0; langCodes[i] != NULL; i++) {
        NSString *label = [NSString stringWithUTF8String:langNames[i]];
        NSString *code = [NSString stringWithUTF8String:langCodes[i]];
        [languagePopup addItemWithTitle:label];
        [[languagePopup lastItem] setRepresentedObject:code];
    }
    [languagePopup setTarget:self];
    [languagePopup setAction:@selector(languageChanged:)];
    [contentView addSubview:languagePopup];

    translateCheckbox = [[NSButton alloc] initWithFrame:NSZeroRect];
    [translateCheckbox setButtonType:NSSwitchButton];
    [translateCheckbox setTitle:@"Translate to English"];
    [translateCheckbox setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [translateCheckbox sizeToFit];
    [contentView addSubview:translateCheckbox];

    threadsLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [threadsLabel setEditable:NO];
    [threadsLabel setBordered:NO];
    [threadsLabel setDrawsBackground:NO];
    [threadsLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [threadsLabel setStringValue:@"Threads:"];
    [threadsLabel sizeToFit];
    [contentView addSubview:threadsLabel];
    [threadsLabel release];

    int defaultThreads = (int)[[NSProcessInfo processInfo] processorCount];
    if (defaultThreads < 1) defaultThreads = 4;

    threadsField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [threadsField setIntValue:defaultThreads];
    [threadsField setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [threadsField setAlignment:NSRightTextAlignment];
    [threadsField setBezeled:YES];
    [threadsField setEditable:YES];
    [threadsField setTarget:self];
    [threadsField setAction:@selector(threadsChanged:)];
    [contentView addSubview:threadsField];

    threadsStepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    [threadsStepper setMinValue:1];
    [threadsStepper setMaxValue:32];
    [threadsStepper setIntValue:defaultThreads];
    [threadsStepper setTarget:self];
    [threadsStepper setAction:@selector(threadsChanged:)];
    [threadsStepper sizeToFit];
    [contentView addSubview:threadsStepper];

    // Transcribe button & progress
    transcribeButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [transcribeButton setTitle:@"Transcribe"];
    [transcribeButton setTarget:self];
    [transcribeButton setAction:@selector(transcribe:)];
    [transcribeButton setBezelStyle:NSRoundedBezelStyle];
    [transcribeButton sizeToFit];
    [contentView addSubview:transcribeButton];

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
    [statusLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [statusLabel setTextColor:[NSColor grayColor]];
    [statusLabel setStringValue:@"Ready"];
    [contentView addSubview:statusLabel];

    // Results text view
    resultScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    [resultScrollView setHasVerticalScroller:YES];
    [resultScrollView setAutohidesScrollers:YES];
    [resultScrollView setBorderType:NSBezelBorder];
    [resultScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [contentView addSubview:resultScrollView];

    resultTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    [resultTextView setEditable:NO];
    [resultTextView setFont:[NSFont userFixedPitchFontOfSize:12]];
    [resultTextView setVerticallyResizable:YES];
    [resultTextView setHorizontallyResizable:NO];
    [resultTextView setAutoresizingMask:NSViewWidthSizable];
    [resultScrollView setDocumentView:resultTextView];
    // scroll view now owns resultTextView; we keep a zero-ing ivar so it
    // must NOT be released here (non-ARC: the scroll view retains it).
    // (We deliberately do NOT send extra release to keep the ivar valid.)

    // Export buttons
    saveTxtButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [saveTxtButton setTitle:@"Save as TXT"];
    [saveTxtButton setTarget:self];
    [saveTxtButton setAction:@selector(saveAsTxt:)];
    [saveTxtButton setBezelStyle:NSRoundedBezelStyle];
    [saveTxtButton sizeToFit];
    [saveTxtButton setEnabled:NO];
    [contentView addSubview:saveTxtButton];

    saveSrtButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [saveSrtButton setTitle:@"Save as SRT"];
    [saveSrtButton setTarget:self];
    [saveSrtButton setAction:@selector(saveAsSrt:)];
    [saveSrtButton setBezelStyle:NSRoundedBezelStyle];
    [saveSrtButton sizeToFit];
    [saveSrtButton setEnabled:NO];
    [contentView addSubview:saveSrtButton];

    saveVttButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [saveVttButton setTitle:@"Save as VTT"];
    [saveVttButton setTarget:self];
    [saveVttButton setAction:@selector(saveAsVtt:)];
    [saveVttButton setBezelStyle:NSRoundedBezelStyle];
    [saveVttButton sizeToFit];
    [saveVttButton setEnabled:NO];
    [contentView addSubview:saveVttButton];

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
    NSSize openSize = [openButton frame].size;

    [recordButton setFrame:NSMakeRect(mx, y - bh, recSize.width, bh)];
    [stopButton setFrame:NSMakeRect(mx + recSize.width + s8, y - bh,
                                    stopSize.width, bh)];

    CGFloat spinnerW = [recordSpinner frame].size.width;
    CGFloat statusX  = mx + recSize.width + s8 + stopSize.width + s8;
    [recordSpinner setFrame:NSMakeRect(statusX, y - bh + (bh - spinnerW) / 2,
                                       spinnerW, spinnerW)];
    CGFloat statusW  = w - (recSize.width + s8 + stopSize.width + s8 +
                            spinnerW + s8 + openSize.width + s8);
    if (statusW < 20) statusW = 20;
    [recordStatusLabel setFrame:NSMakeRect(statusX + spinnerW + s8,
                                           y - bh, statusW, bh)];
    [openButton setFrame:NSMakeRect(statusX + statusW + s8, y - bh,
                                    openSize.width, bh)];
    y -= bh + s8;

    // ---- Row 2: File path ----
    [filePathLabel setFrame:NSMakeRect(mx, y - bh, w, bh)];
    y -= bh + s16;

    // ---- Row 3: Model ----
    CGFloat mLW = [modelLabel frame].size.width + 4;
    NSSize dlSz = [downloadButton frame].size;
    CGFloat prW = 80;
    CGFloat popW = w - mLW - s8 - dlSz.width - s8 - prW;
    if (popW < 120) popW = 120;

    [modelLabel setFrame:NSMakeRect(mx, y - bh, mLW, bh)];
    [modelPopup setFrame:NSMakeRect(mx + mLW, y - 2, popW, bh + 4)];
    [downloadButton setFrame:NSMakeRect(mx + mLW + popW + s8, y - 2,
                                        dlSz.width, bh + 4)];
    [downloadProgress setFrame:NSMakeRect(
        mx + mLW + popW + s8 + dlSz.width + s8,
        y, w - (mLW + popW + s8 + dlSz.width + s8), bh)];
    y -= bh + s16 + 4;

    // ---- Row 4: Settings ----
    CGFloat lLW = [langLabel frame].size.width + 4;
    CGFloat lPW = 130;

    // Threads section: right-aligned
    CGFloat tLW = [threadsLabel frame].size.width + 4;
    CGFloat tFW = 40;
    CGFloat tSW = [threadsStepper frame].size.width;
    CGFloat threadsWidth = tLW + s8 + tFW + s8 + tSW;
    CGFloat cbW = [[translateCheckbox cell] cellSize].width;
    CGFloat gapForCheckbox = w - (lLW + lPW + s16 + threadsWidth);
    if (gapForCheckbox < cbW) {
        // Not enough room — shrink language popup
        lPW = 100;
        gapForCheckbox = w - (lLW + 100 + s16 + threadsWidth);
        if (gapForCheckbox < cbW) gapForCheckbox = cbW;
    }
    CGFloat lPopupEnd = mx + lLW + lPW;
    CGFloat threadsX  = mx + w - threadsWidth;

    [langLabel setFrame:NSMakeRect(mx, y - bh, lLW, bh)];
    [languagePopup setFrame:NSMakeRect(mx + lLW, y - 2, lPW, bh + 4)];
    [translateCheckbox setFrame:NSMakeRect(lPopupEnd + s16, y,
                                           gapForCheckbox,
                                           METRICS_RADIO_BUTTON_LINE_SPACING)];
    [threadsLabel setFrame:NSMakeRect(threadsX, y - bh, tLW, bh)];
    [threadsField setFrame:NSMakeRect(threadsX + tLW + s8, y - 1,
                                      tFW, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    [threadsStepper setFrame:NSMakeRect(threadsX + tLW + s8 + tFW + s8, y - 1,
                                        tSW, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    y -= bh + s16;

    // ---- Row 5: Transcribe button + progress ----
    CGFloat tBW = 100;
    [transcribeButton setFrame:NSMakeRect(mx, y - 2, tBW, bh + 4)];
    [progressBar setFrame:NSMakeRect(mx + tBW + s8, y,
                                     w - tBW - s8, bh)];
    y -= bh + s8;

    // ---- Status label ----
    [statusLabel setFrame:NSMakeRect(mx, y - bh, w, bh)];
    y -= s8;

    // ---- Results (fills remaining) ----
    CGFloat exportH = bh + METRICS_SPACE_12;
    CGFloat textY   = mb + exportH + s8;
    [resultScrollView setFrame:NSMakeRect(mx, textY, w, y - textY)];

    // ---- Export buttons ----
    [saveTxtButton  setFrame:NSMakeRect(mx, mb, 100, bh)];
    [saveSrtButton  setFrame:NSMakeRect(mx + 108, mb, 100, bh)];
    [saveVttButton  setFrame:NSMakeRect(mx + 216, mb, 100, bh)];
}

- (void)windowDidResize:(NSNotification *)notification
{
    [self layoutSubviews];
}

@end
