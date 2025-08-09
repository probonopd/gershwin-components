//
// CLMImageSelectionStep.h
// Create Live Media Assistant - Image Selection Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@class CLMController;

@interface CLMImageSelectionStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    CLMController *_controller;
    NSPopUpButton *_repositoryPopUp;
    NSTableView *_releaseTableView;
    NSArrayController *_releaseArrayController;
    NSButton *_prereleaseCheckbox;
    NSTextField *_dateLabel;
    NSTextField *_urlLabel;
    NSTextField *_sizeLabel;
    NSProgressIndicator *_loadingIndicator;
    NSTextField *_loadingLabel;
    NSMutableArray *_availableReleases;
    BOOL _isLoading;
}

@property (nonatomic, assign) CLMController *controller;

@end
