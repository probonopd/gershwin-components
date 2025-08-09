//
// CLMIntroStep.h
// Create Live Media Assistant - Introduction Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@interface CLMIntroStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
}

@end
