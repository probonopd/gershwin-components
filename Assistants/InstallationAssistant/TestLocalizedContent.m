#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"=== Testing Localized Content Manager ===");
        
        // Test content availability
        NSLog(@"\n--- Content Availability Tests ---");
        BOOL hasWelcome = [GSLocalizedContentManager hasWelcomeContent];
        BOOL hasReadMe = [GSLocalizedContentManager hasReadMeContent];
        BOOL hasLicense = [GSLocalizedContentManager hasLicenseContent];
        
        NSLog(@"Welcome content available: %@", hasWelcome ? @"YES" : @"NO");
        NSLog(@"ReadMe content available: %@", hasReadMe ? @"YES" : @"NO");
        NSLog(@"License content available: %@", hasLicense ? @"YES" : @"NO");
        
        // Test content retrieval
        NSLog(@"\n--- Content Retrieval Tests ---");
        if (hasWelcome) {
            NSString *welcomeContent = [GSLocalizedContentManager welcomeContent];
            NSLog(@"Welcome content preview: %@...", 
                  [welcomeContent substringToIndex:MIN(80, welcomeContent.length)]);
        }
        
        if (hasReadMe) {
            NSString *readMeContent = [GSLocalizedContentManager readMeContent];
            NSLog(@"ReadMe content preview: %@...", 
                  [readMeContent substringToIndex:MIN(80, readMeContent.length)]);
        }
        
        if (hasLicense) {
            NSString *licenseContent = [GSLocalizedContentManager licenseContent];
            NSLog(@"License content preview: %@...", 
                  [licenseContent substringToIndex:MIN(80, licenseContent.length)]);
        }
        
        // Test step creation
        NSLog(@"\n--- Step Creation Tests ---");
        id<GSAssistantStepProtocol> welcomeStep = [GSLocalizedContentManager createWelcomeStep];
        id<GSAssistantStepProtocol> readMeStep = [GSLocalizedContentManager createReadMeStep];
        id<GSAssistantStepProtocol> licenseStep = [GSLocalizedContentManager createLicenseStep];
        
        NSLog(@"Welcome step created: %@", welcomeStep ? @"SUCCESS" : @"FAILED");
        NSLog(@"ReadMe step created: %@", readMeStep ? @"SUCCESS" : @"FAILED");
        NSLog(@"License step created: %@", licenseStep ? @"SUCCESS" : @"FAILED");
        
        if (welcomeStep) {
            NSLog(@"  Welcome step title: '%@'", [welcomeStep stepTitle]);
            NSLog(@"  Welcome step description: '%@'", [welcomeStep stepDescription]);
        }
        
        if (readMeStep) {
            NSLog(@"  ReadMe step title: '%@'", [readMeStep stepTitle]);
            NSLog(@"  ReadMe step description: '%@'", [readMeStep stepDescription]);
        }
        
        if (licenseStep) {
            NSLog(@"  License step title: '%@'", [licenseStep stepTitle]);
            NSLog(@"  License step description: '%@'", [licenseStep stepDescription]);
        }
        
        NSLog(@"\n=== Test Completed ===");
    }
    return 0;
}
