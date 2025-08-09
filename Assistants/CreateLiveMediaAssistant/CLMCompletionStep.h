//
// CLMCompletionStep.h
// Create Live Media Assistant - Completion Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@interface CLMCompletionStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
}

@end
