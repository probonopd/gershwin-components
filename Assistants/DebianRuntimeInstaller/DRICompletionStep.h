//
// DRICompletionStep.h
// Debian Runtime Installer - Completion Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@interface DRICompletionStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_contentView;
    NSImageView *_statusIcon;
    NSTextField *_statusLabel;
    NSTextView *_nextStepsView;
}

- (void)setInstallationSuccessful:(BOOL)successful withMessage:(NSString *)message;

@end
