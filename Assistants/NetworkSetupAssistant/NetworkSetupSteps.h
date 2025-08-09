//
// NetworkSetupSteps.h
// Network Setup Assistant - Custom Step Classes
//

#import <Foundation/Foundation.h>
#import "GSAssistantFramework.h"

// Network Configuration Step
@interface NSNetworkConfigStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSPopUpButton *_interfacePopup;
    NSButton *_dhcpRadio;
    NSButton *_manualRadio;
    NSTextField *_ipAddressField;
    NSTextField *_subnetMaskField;
    NSTextField *_gatewayField;
    NSTextField *_dnsField;
}

@property (readonly, nonatomic) NSView *stepView;
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;

- (NSString *)selectedInterface;
- (BOOL)usesDHCP;
- (NSString *)ipAddress;
- (NSString *)subnetMask;
- (NSString *)gateway;
- (NSString *)dnsServer;

@end

// Authentication Configuration Step
@interface NSAuthConfigStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSTextField *_usernameField;
    NSSecureTextField *_passwordField;
    NSTextField *_domainField;
    NSButton *_enableWPACheckbox;
    NSSecureTextField *_wpaPasswordField;
}

@property (readonly, nonatomic) NSView *stepView;
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;

- (NSString *)username;
- (NSString *)password;
- (NSString *)domain;
- (BOOL)enableWPA;
- (NSString *)wpaPassword;

@end
