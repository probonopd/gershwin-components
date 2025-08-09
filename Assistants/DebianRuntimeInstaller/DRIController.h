//
// DRIController.h
// Debian Runtime Installer - Main Controller
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@interface DRIController : NSObject <GSAssistantWindowDelegate>
{
    GSAssistantWindow *_assistantWindow;
    NSString *_selectedImageURL;
    NSString *_selectedImageName;
    long long _selectedImageSize;
    BOOL _installationSuccessful;
}

- (void)showAssistant;

// Success and error handling
- (void)showInstallationSuccess:(NSString *)message;
- (void)showInstallationError:(NSString *)message;

@end
