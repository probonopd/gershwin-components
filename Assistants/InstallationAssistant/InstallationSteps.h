//
// InstallationSteps.h
// Installation Assistant - Custom Step Classes
//

#import <Foundation/Foundation.h>
#import "GSAssistantFramework.h"

// License Agreement Step
@interface IALicenseStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSTextView *_licenseTextView;
    NSButton *_agreeCheckbox;
}

@property (readonly, nonatomic) NSView *stepView;
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;

- (BOOL)userAgreedToLicense;

@end

// Installation Location Step
@interface IADestinationStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSPopUpButton *_destinationPopup;
    NSTextField *_spaceRequiredLabel;
    NSTextField *_spaceAvailableLabel;
}

@property (readonly, nonatomic) NSView *stepView;
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;

- (NSString *)selectedDestination;

@end

// Installation Options Step
@interface IAOptionsStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSButton *_installDevelopmentToolsCheckbox;
    NSButton *_installLinuxCompatibilityCheckbox;
    NSButton *_installDocumentationCheckbox;
}

@property (readonly, nonatomic) NSView *stepView;
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;

- (BOOL)installDevelopmentTools;
- (BOOL)installLinuxCompatibility;
- (BOOL)installDocumentation;

@end
