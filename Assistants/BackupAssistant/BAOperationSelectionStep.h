//
// BAOperationSelectionStep.h
// Backup Assistant - Operation Selection Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@class BAController;

@interface BAOperationSelectionStep : GSAssistantStep
{
    BAController *_controller;
    NSView *_containerView;
    NSMatrix *_operationMatrix;
    NSTextField *_diskInfoLabel;
    NSTextField *_warningLabel;
}

@property (nonatomic, assign) BAController *controller;

- (id)initWithController:(BAController *)controller;
- (void)updateOperationOptions;

@end
