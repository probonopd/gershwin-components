//
// BhyveIntroStep.h
// Bhyve Assistant - Introduction Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@interface BhyveIntroStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
}

@end
