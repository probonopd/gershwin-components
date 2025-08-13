//
// BhyveRunningStep.h
// Bhyve Assistant - VM Running Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@class BhyveController;

@interface BhyveRunningStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSTextField *_statusLabel;
    NSTextField *_vmInfoLabel;
    NSButton *_startButton;
    NSButton *_stopButton;
    NSButton *_logButton;
    BhyveController *_controller;
}

@property (nonatomic, assign) BhyveController *controller;

- (void)updateStatus:(NSString *)status;

@end
