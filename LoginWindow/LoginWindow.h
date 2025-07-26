#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "LoginWindowPAM.h"

@interface LoginWindow : NSObject
{
    NSWindow *loginWindow;
    NSTextField *usernameField;
    NSSecureTextField *passwordField;
    NSButton *loginButton;
    NSButton *shutdownButton;
    NSButton *restartButton;
    NSImageView *logoView;
    NSTextField *statusLabel;
    LoginWindowPAM *pamAuth;
    NSPopUpButton *sessionDropdown;
    NSArray *availableSessions;
    NSArray *availableSessionExecs;
    NSString *selectedSessionExec;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)createLoginWindow;
- (void)loginButtonPressed:(id)sender;
- (void)shutdownButtonPressed:(id)sender;
- (void)restartButtonPressed:(id)sender;
- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password;
- (void)startUserSession:(NSString *)username;
- (void)showStatus:(NSString *)message;
- (void)sessionChanged:(id)sender;
- (void)resetLoginWindow;
- (BOOL)trySystemAction:(NSString *)actionType;

@end
