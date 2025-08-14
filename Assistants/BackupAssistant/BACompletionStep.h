//
// BACompletionStep.h
// Backup Assistant - Completion Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@class BAController;

@interface BACompletionStep : GSCompletionStep
{
    BAController *_controller;
}

@property (nonatomic, assign) BAController *controller;

- (id)initWithController:(BAController *)controller;

@end
