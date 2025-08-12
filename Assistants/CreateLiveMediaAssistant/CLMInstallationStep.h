//
// CLMInstallationStep.h
// Create Live Media Assistant - Installation Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import "GSNetworkUtilities.h"

@class CLMController;

@interface CLMInstallationStep : NSObject <GSAssistantStepProtocol, GSDownloaderDelegate>
{
    NSView *_stepView;
    CLMController *_controller;
    NSProgressIndicator *_progressBar;
    NSTextField *_statusLabel;
    NSTextField *_progressLabel;
    NSTextField *_infoLabel;
    GSDownloader *_downloader;
    BOOL _installationInProgress;
    BOOL _installationCompleted;
    BOOL _installationSuccessful;
    
    // Stall detection
    NSTimer *_stallDetectionTimer;
    NSTimeInterval _lastProgressTime;
    float _lastProgressValue;
    
    // DD progress simulation timer
    NSTimer *_ddProgressTimer;
    NSTimeInterval _ddStartTime;
    
    // Direct download approach using NSURLConnection
    NSURLConnection *_directConnection;
    NSFileHandle *_directOutputFile;
    NSString *_devicePath;
    NSString *_tempFilePath;
    long long _directTotalBytes;
    long long _directReceivedBytes;
}

@property (nonatomic, assign) CLMController *controller;

@end
