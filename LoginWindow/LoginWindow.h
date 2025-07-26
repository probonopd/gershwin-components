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
    pid_t sessionPid;
    uid_t sessionUid;
    gid_t sessionGid;
    BOOL didStartXServer;
    pid_t xServerPid;
    BOOL isTerminating;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
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
- (void)killAllSessionProcesses:(uid_t)uid;
- (BOOL)isXServerRunning;
- (BOOL)startXServer;
- (void)ensureXServerRunning;
- (void)stopXServerIfStartedByUs;
- (void)cleanupExistingXServer;
- (void)shakeWindow;
- (void)saveLastLoggedInUser:(NSString *)username;
- (NSString *)loadLastLoggedInUser;

@end
