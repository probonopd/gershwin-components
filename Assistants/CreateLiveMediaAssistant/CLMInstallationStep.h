//
// CLMInstallationStep.h
// Create Live Media Assistant - Installation Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import "CLMDownloader.h"

@class CLMController;

@interface CLMInstallationStep : NSObject <GSAssistantStepProtocol, CLMDownloaderDelegate>
{
    NSView *_stepView;
    CLMController *_controller;
    NSProgressIndicator *_progressBar;
    NSTextField *_statusLabel;
    NSTextField *_progressLabel;
    NSTextField *_infoLabel;
    CLMDownloader *_downloader;
    BOOL _installationInProgress;
    BOOL _installationCompleted;
    BOOL _installationSuccessful;
}

@property (nonatomic, assign) CLMController *controller;

@end
