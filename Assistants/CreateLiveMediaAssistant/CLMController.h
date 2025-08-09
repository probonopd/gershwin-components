//
// CLMController.h
// Create Live Media Assistant - Main Controller
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@interface CLMController : NSObject <GSAssistantWindowDelegate>
{
    GSAssistantWindow *_assistantWindow;
    NSString *_selectedImageURL;
    NSString *_selectedImageName;
    long long _selectedImageSize;
    NSString *_selectedDiskDevice;
    BOOL _userAgreedToErase;
    BOOL _installationSuccessful;
    NSArray *_availableRepositories;
    NSArray *_availableReleases;
    BOOL _showPrereleases;
}

@property (nonatomic, retain) NSString *selectedImageURL;
@property (nonatomic, retain) NSString *selectedImageName;
@property (nonatomic, assign) long long selectedImageSize;
@property (nonatomic, retain) NSString *selectedDiskDevice;
@property (nonatomic, assign) BOOL userAgreedToErase;
@property (nonatomic, assign) BOOL installationSuccessful;
@property (nonatomic, retain) NSArray *availableRepositories;
@property (nonatomic, retain) NSArray *availableReleases;
@property (nonatomic, assign) BOOL showPrereleases;

- (void)showAssistant;

// Success and error handling
- (void)showInstallationSuccess:(NSString *)message;
- (void)showInstallationError:(NSString *)message;

// Helper methods
- (BOOL)checkInternetConnection;
- (long long)requiredDiskSpaceInMiB;
- (void)stopDiskPolling; // Failsafe to stop disk polling from any step
@end
