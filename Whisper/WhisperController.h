/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef WHISPER_CONTROLLER_H
#define WHISPER_CONTROLLER_H

#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, WhisperState) {
    WhisperStateIdle,
    WhisperStateLoadingModel,
    WhisperStateRecording,
    WhisperStateTranscribing,
    WhisperStateDone,
    WhisperStateError
};

@interface WhisperController : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
{
    // Main window
    NSWindow *mainWindow;

    // File selection
    NSString *currentFilePath;

    // Recording
    NSButton *recordButton;
    NSButton *stopButton;
    NSProgressIndicator *recordSpinner;

    // Model management
    NSString *modelDir;
    NSProgressIndicator *downloadProgress;
    NSArray *availableModels;

    // Settings
    // NSButton *translateCheckbox;
    int currentThreads;

    // Action
    NSProgressIndicator *progressBar;
    NSTextField *statusLabel;

    // Results
    NSTextView *resultTextView;
    NSScrollView *resultScrollView;

    // Export
    NSButton *copyTextButton;
    NSButton *showTimestampsCheckbox;
    NSButton *newlinesCheckbox;
    BOOL showTimestamps;
    BOOL showNewlines;
    BOOL copyDefaultConsumed;
    NSString *typedText;
    unsigned long targetWindowID;
    NSString *vocabularyPrompt;

    // Whisper state
    struct whisper_context *whisperCtx;
    WhisperState state;
    NSMutableArray *segments;

    // Timing
    NSTimeInterval transcriptionStartTime;

    // Recording state
    void *captureHandle;
    NSString *currentLangCode;
    NSTimer *recordTimer;
    NSTimer *streamTimer;
    NSTimeInterval recordStartTime;
    int lastSegmentCount;
    BOOL isTranscribing;

    // Vocabulary editor
    NSPanel *vocabPanel;
    NSTextView *vocabTextView;

    // Model download
    BOOL firstRealProgress;
    NSTask *downloadTask;
    NSString *downloadingModel;
    NSMutableData *downloadData;
    NSFileHandle *downloadFH;
}

@property (retain) NSWindow *mainWindow;
@property (retain) NSArray *availableModels;
@property (retain) NSMutableArray *segments;
@property (retain) NSString *currentFilePath;

// UI creation
- (void)createUI;
- (void)createMenu;

// Layout
- (void)layoutSubviews;

// Window delegate
- (void)windowDidResize:(NSNotification *)notification;

// App delegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename;

// Actions
- (IBAction)recordAudio:(id)sender;
- (IBAction)stopRecording:(id)sender;
- (IBAction)openFile:(id)sender;
- (IBAction)modelSelected:(id)sender;
- (IBAction)languageChanged:(id)sender;
- (IBAction)threadSelected:(id)sender;
- (IBAction)saveAsTxt:(id)sender;
- (IBAction)saveAsSrt:(id)sender;
- (IBAction)saveAsVtt:(id)sender;
- (IBAction)copyText:(id)sender;
- (IBAction)timestampsToggled:(id)sender;
- (IBAction)newlinesToggled:(id)sender;
- (IBAction)editVocabulary:(id)sender;

// Transcription
- (void)transcriptionThread:(id)object;
- (void)transcriptionProgress:(NSNumber *)progress;
- (void)transcriptionFinished:(NSString *)result;
- (void)transcriptionFailed:(NSString *)error;

// Model management
- (void)populateModelList;
- (NSString *)modelPathForName:(NSString *)name;
- (void)downloadModelWithName:(NSString *)name;

// Export
- (NSString *)formatTimestamp:(int64_t)t;
- (NSString *)formatTimestampSrt:(int64_t)t;
- (NSString *)formatTimestampVtt:(int64_t)t;
- (void)saveTranscriptionWithFormat:(NSString *)format;

// Audio loading
- (float *)loadAudio:(NSString *)path outSamples:(int *)outNSamples outSampleRate:(int *)outSampleRate;

// State
- (void)setState:(WhisperState)newState;
- (void)updateUIForState;

// Display
- (NSString *)displayTextFromSegments;
- (void)rebuildTextView;

// Auto-type
- (NSString *)plainTextFromSegments;
- (void)syncTypedText;
- (void)typeTextToApp:(NSString *)text;
- (void)typeBackspaces:(int)count;

@end
#endif
