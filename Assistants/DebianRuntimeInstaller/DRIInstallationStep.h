//
// DRIInstallationStep.h
// Debian Runtime Installer - Installation Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import "DRIDownloader.h"
#import "DRIInstaller.h"
#import "DRIController.h"

@interface DRIInstallationStep : NSObject <GSAssistantStepProtocol, DRIDownloaderDelegate, DRIInstallerDelegate>
{
    NSView *_stepView;
    DRIDownloader *_downloader;
    DRIInstaller *_installer;
    NSString *_selectedImageURL;
    NSString *_downloadPath;
    DRIController *_controller;  // Reference to controller for success/error pages
    
    // UI elements
    NSProgressIndicator *_progressBar;
    NSTextField *_statusLabel;
    NSTextView *_logView;
    
    // Progress tracking
    BOOL _installationCompleted;
    CGFloat _currentProgress;
    NSString *_currentTask;
}

- (void)setSelectedImageURL:(NSString *)url;
- (void)setController:(DRIController *)controller;
- (void)cancel;

@end
