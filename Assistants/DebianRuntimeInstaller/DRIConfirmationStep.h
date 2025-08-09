//
// DRIConfirmationStep.h
// Debian Runtime Installer - Confirmation Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@interface DRIConfirmationStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_contentView;
    NSTextView *_summaryView;
}

- (void)setSelectedImageURL:(NSString *)url;
- (void)setSelectedImageName:(NSString *)name;
- (void)setSelectedImageSize:(long long)size;

@end
