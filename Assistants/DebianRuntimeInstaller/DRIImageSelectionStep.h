//
// DRIImageSelectionStep.h
// Debian Runtime Installer - Image Selection Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import <GSNetworkUtilities.h>
#import "DRIGitHubAPI.h"

@interface DRIImageSelectionStep : GSSelectionStep
{
    NSTextField *_urlField;
    NSButton *_prereleaseCheckbox;
    NSString *_selectedImageURL;
    NSButton *_refreshButton;
}

- (NSString *)getSelectedImageURL;
- (long long)getSelectedImageSize;
- (NSString *)getSelectedImageName;

@end
