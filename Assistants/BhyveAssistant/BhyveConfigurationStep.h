//
// BhyveConfigurationStep.h
// Bhyve Assistant - VM Configuration Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@class BhyveController;

@interface BhyveConfigurationStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSTextField *_vmNameField;
    NSSlider *_ramSlider;
    NSTextField *_ramLabel;
    NSSlider *_cpuSlider;
    NSTextField *_cpuLabel;
    NSSlider *_diskSlider;
    NSTextField *_diskLabel;
    NSButton *_vncCheckbox;
    NSTextField *_vncPortField;
    NSPopUpButton *_networkPopup;
    NSPopUpButton *_bootModePopup;
    BhyveController *_controller;
}

@property (nonatomic, assign) BhyveController *controller;

@end
