//
// SystemSetupSteps.h
// System Setup Assistant - Custom Step Classes
//

#import <Foundation/Foundation.h>
#import "GSAssistantFramework.h"

// User Information Step
@interface SSUserInfoStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSTextField *_usernameField;
    NSTextField *_fullNameField;
    NSSecureTextField *_passwordField;
    NSSecureTextField *_confirmPasswordField;
}

@property (readonly, nonatomic) NSView *stepView;
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;

- (NSString *)username;
- (NSString *)fullName;
- (NSString *)password;

@end

// System Preferences Step
@interface SSPreferencesStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSButton *_enableFirewallCheckbox;
    NSButton *_enableUpdateCheckbox;
    NSButton *_enableLocationCheckbox;
    NSPopUpButton *_timezonePopup;
}

@property (readonly, nonatomic) NSView *stepView;
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;

- (BOOL)enableFirewall;
- (BOOL)enableAutomaticUpdates;
- (BOOL)enableLocationServices;
- (NSString *)selectedTimezone;

@end
