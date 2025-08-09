#import "GSInstallerAssistant.h"

@interface GSInstallerAssistantTest : NSObject

+ (void)runInstallerDemo;

@end

@implementation GSInstallerAssistantTest

+ (void)runInstallerDemo {
    NSLog(@"[GSInstallerAssistantTest] Starting installer assistant demo");
    
    // Create sample application icons for the introduction step
    NSMutableArray *appIcons = [[NSMutableArray alloc] init];
    
    // Create placeholder colored icons
    for (int i = 0; i < 5; i++) {
        NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(48, 48)];
        [icon lockFocus];
        
        // Create a colored circle as placeholder icon
        NSColor *color = nil;
        switch (i) {
            case 0: color = [NSColor blueColor]; break;
            case 1: color = [NSColor orangeColor]; break;
            case 2: color = [NSColor redColor]; break;
            case 3: color = [NSColor greenColor]; break;
            case 4: color = [NSColor purpleColor]; break;
            default: color = [NSColor grayColor]; break;
        }
        
        [color setFill];
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4, 4, 40, 40)];
        [circle fill];
        
        [icon unlockFocus];
        [appIcons addObject:icon];
        [icon release];
    }
    
    // Create installer steps
    NSMutableArray *steps = [[NSMutableArray alloc] init];
    
    // 1. Introduction step
    GSModernIntroductionStep *introStep = [[GSModernIntroductionStep alloc] 
        initWithWelcomeMessage:@"To install, click Continue then follow the onscreen instructions.\n\nTo quit, choose Quit Installer from the Installer menu and click Startup Disk.\n\nRead the following information before you install."
        icons:appIcons];
    [steps addObject:introStep];
    [introStep release];
    
    // 2. License step (using base step for simplicity)
    GSModernInstallerStep *licenseStep = [[GSModernInstallerStep alloc] 
        initWithTitle:@"Read Me" 
        description:@"Please read the following important information"];
    [steps addObject:licenseStep];
    [licenseStep release];
    
    // 3. License agreement step
    GSModernInstallerStep *agreementStep = [[GSModernInstallerStep alloc] 
        initWithTitle:@"License" 
        description:@"Please read the software license agreement"];
    [steps addObject:agreementStep];
    [agreementStep release];
    
    // 4. Destination selection step
    GSModernDestinationStep *destStep = [[GSModernDestinationStep alloc] 
        initWithTitle:@"Select Destination" 
        description:@"Select a destination volume to install the software"];
    [steps addObject:destStep];
    [destStep release];
    
    // 5. Installation type step
    GSModernInstallerStep *typeStep = [[GSModernInstallerStep alloc] 
        initWithTitle:@"Installation Type" 
        description:@"Choose the type of installation"];
    [steps addObject:typeStep];
    [typeStep release];
    
    // 6. Installation progress step
    GSModernInstallationProgressStep *progressStep = [[GSModernInstallationProgressStep alloc] 
        initWithTitle:@"Installing" 
        description:@"Installing the software"];
    [steps addObject:progressStep];
    [progressStep release];
    
    // 7. Completion step
    GSModernCompletionStep *completionStep = [[GSModernCompletionStep alloc] 
        initWithTitle:@"Finish Up" 
        description:@"Installation completed successfully"];
    [steps addObject:completionStep];
    [completionStep release];
    
    // Create installer assistant window
    GSModernInstallerWindow *installer = [[GSModernInstallerWindow alloc] 
        initWithTitle:@"Install Gershwin" 
        icon:nil
        steps:steps];
    
    // Show the installer window
    [[installer window] makeKeyAndOrderFront:nil];
    
    NSLog(@"[GSInstallerAssistantTest] Installer assistant demo window created and displayed");
    
    [appIcons release];
    [steps release];
    [installer release];
}

@end

int main(int argc, const char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSApplication *app = [NSApplication sharedApplication];
    
    // Run the installer demo
    [GSInstallerAssistantTest runInstallerDemo];
    
    // Run the application
    [app run];
    
    [pool release];
    return 0;
}
