//
// CLMDiskSelectionStep.h
// Create Live Media Assistant - Disk Selection Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@class CLMController;

@interface CLMDiskSelectionStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    CLMController *_controller;
    NSTableView *_diskTableView;
    NSArrayController *_diskArrayController;
    NSTextField *_infoLabel;
    NSTextField *_warningLabel;
    NSMutableArray *_availableDisks;
    NSTimer *_refreshTimer;
}

@property (nonatomic, assign) CLMController *controller;

// Disk refresh control
- (void)stopRefreshTimer;

@end
