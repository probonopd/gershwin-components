//
// BAProgressStep.h
// Backup Assistant - Progress Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@class BAController;

@interface BAProgressStep : GSAssistantStep
{
    BAController *_controller;
    NSTextField *_operationLabel;
    NSTextField *_currentTaskLabel;
    NSProgressIndicator *_progressBar;
    NSTextField *_progressLabel;
    BOOL _operationInProgress;
}

@property (nonatomic, assign) BAController *controller;

- (id)initWithController:(BAController *)controller;
- (void)startOperation;
- (void)performOperation;
- (void)updateProgressFromBackground:(NSDictionary *)progressInfo;
- (void)handleOperationResult:(NSDictionary *)resultInfo;

@end
