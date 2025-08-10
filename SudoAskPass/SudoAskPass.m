#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/message.h>
#include <fcntl.h>
#include <unistd.h>

// Override NSAlert to prevent any alerts from showing
@interface NSAlert (SuppressAlerts)
@end

@implementation NSAlert (SuppressAlerts)

// Suppress category override warnings
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

+ (void)load
{
    // Disable all alert methods by replacing them with no-ops
    // This prevents any system alerts from showing
}

- (NSInteger)runModal
{
    // Return immediately without showing alert
    return NSAlertFirstButtonReturn;
}

- (void)beginSheetModalForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)didEndSelector contextInfo:(void *)contextInfo
{
    // Do nothing - don't show alert sheet
    if (delegate && didEndSelector) {
        // Call the delegate immediately with default response using objc_msgSend
        if ([delegate respondsToSelector:didEndSelector]) {
            ((void(*)(id, SEL, id, id))objc_msgSend)(delegate, didEndSelector, self, [NSNumber numberWithInteger:NSAlertFirstButtonReturn]);
        }
    }
}

@end

#pragma clang diagnostic pop

@interface SudoAskPassController : NSObject<NSTextFieldDelegate>
{
    NSWindow *window;
    NSSecureTextField *passwordField;
    NSTextField *promptLabel;
    NSButton *okButton;
    NSButton *cancelButton;
    NSButton *detailsButton;
    NSTextField *commandLabel;
    NSScrollView *commandScrollView;
    NSString *sudoCommand;
    BOOL cancelled;
    BOOL detailsVisible;
}

- (void)showPasswordDialog;
- (void)checkPasswordRequiredAndShowDialog;
- (BOOL)validatePassword:(NSString *)password;
- (void)shakeWindow;
- (void)updateOKButtonState;
- (void)okClicked:(id)sender;
- (void)cancelClicked:(id)sender;
- (void)detailsClicked:(id)sender;
- (void)applicationWillFinishLaunching:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;

@end

@implementation SudoAskPassController

- (id)init
{
    self = [super init];
    if (self) {
        cancelled = NO;
        detailsVisible = NO;
    }
    return self;
}

- (void)showPasswordDialog
{

    // Check command line arguments as fallback - extract actual command after sudo options
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    if ([args count] > 1) {
        // Look for the command after sudo options (skip -A, -E, etc.)
        NSMutableArray *commandParts = [NSMutableArray array];
        BOOL foundCommand = NO;
        for (int i = 1; i < [args count]; i++) {
            NSString *arg = [args objectAtIndex:i];
            // Skip sudo options that start with dash
            if ([arg hasPrefix:@"-"] && !foundCommand) {
                continue;
            }
            foundCommand = YES;
            [commandParts addObject:arg];
        }
        if ([commandParts count] > 0) {
            sudoCommand = [[commandParts componentsJoinedByString:@" "] retain];
        } else {
            sudoCommand = [[NSString stringWithFormat:@"Arguments: %@", [args componentsJoinedByString:@" "]] retain];
        }
    }
    

    // Create window with initial size (compact mode)
    NSRect windowRect = NSMakeRect(100, 100, 400, 150);
    window = [[NSWindow alloc] initWithContentRect:windowRect
                                         styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    
    if (!window) {
        // If window creation fails, exit gracefully
        exit(1);
    }
    
    [window setTitle:@"Password"];
    [window center];
    [window setLevel:NSFloatingWindowLevel]; // Keep window on top
    
    // Disable system beeps and alerts for this window
    [window setHidesOnDeactivate:NO];
    
    // Create prompt label
    NSRect promptRect = NSMakeRect(24, 90, 352, 30);
    promptLabel = [[NSTextField alloc] initWithFrame:promptRect];
    [promptLabel setStringValue:@"Enter your password for sudo:"];
    [promptLabel setBezeled:NO];
    [promptLabel setDrawsBackground:NO];
    [promptLabel setEditable:NO];  // Fix: should not be editable
    [promptLabel setSelectable:NO]; // Fix: should not be selectable
    [[window contentView] addSubview:promptLabel];
    
    // Create password field
    NSRect passwordRect = NSMakeRect(24, 60, 352, 22);
    passwordField = [[NSSecureTextField alloc] initWithFrame:passwordRect];
    [passwordField setDelegate:self];  // Set delegate to monitor text changes
    [[window contentView] addSubview:passwordField];
    
    // Create Details button (left side)
    NSRect detailsRect = NSMakeRect(24, 20, 80, 24);
    detailsButton = [[NSButton alloc] initWithFrame:detailsRect];
    [detailsButton setTitle:@"Details"];
    [detailsButton setTarget:self];
    [detailsButton setAction:@selector(detailsClicked:)];
    [[window contentView] addSubview:detailsButton];
    
    // Create OK button (right side, 24px from right edge: 400-24-80 = 296)
    NSRect okRect = NSMakeRect(296, 20, 80, 24);
    okButton = [[NSButton alloc] initWithFrame:okRect];
    [okButton setTitle:@"OK"];
    [okButton setTarget:self];
    [okButton setAction:@selector(okClicked:)];
    [okButton setKeyEquivalent:@"\r"];
    [okButton setEnabled:NO]; // Initially disabled
    [[window contentView] addSubview:okButton];
    
    // Create Cancel button (12px gap from OK: 296-80-12 = 204)
    NSRect cancelRect = NSMakeRect(204, 20, 80, 24);
    cancelButton = [[NSButton alloc] initWithFrame:cancelRect];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(cancelClicked:)];
    [cancelButton setKeyEquivalent:@"\033"];
    [[window contentView] addSubview:cancelButton];
    
    // Create command details (initially hidden)
    NSRect commandRect = NSMakeRect(24, 55, 352, 60);
    commandScrollView = [[NSScrollView alloc] initWithFrame:commandRect];
    [commandScrollView setHasVerticalScroller:YES];
    [commandScrollView setHasHorizontalScroller:YES];
    [commandScrollView setAutohidesScrollers:YES];
    [commandScrollView setBorderType:NSBezelBorder];
    [commandScrollView setHidden:YES];
    
    NSSize contentSize = [commandScrollView contentSize];
    commandLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    [commandLabel setStringValue:[NSString stringWithFormat:@"%@", sudoCommand]];
    [commandLabel setBezeled:NO];
    [commandLabel setDrawsBackground:YES];
    [commandLabel setBackgroundColor:[NSColor controlBackgroundColor]];
    [commandLabel setEditable:NO];
    [commandLabel setSelectable:YES];
    [commandLabel setFont:[NSFont fontWithName:@"Monaco" size:10]];
    [commandScrollView setDocumentView:commandLabel];
    
    [[window contentView] addSubview:commandScrollView];
    
    // Show window immediately and aggressively
    [window makeKeyAndOrderFront:nil];
    [window orderFrontRegardless]; // Force window to front immediately
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    
    // Set focus to password field immediately - no delay
    [window makeFirstResponder:passwordField];
}

- (void)okClicked:(id)sender
{
    NSString *password = [passwordField stringValue];
    
    if (password && [password length] > 0) {
        // Validate password with sudo -Sp
        if ([self validatePassword:password]) {
            // Password is correct, output it and exit
            printf("%s\n", [password UTF8String]);
            fflush(stdout);
            [NSApp terminate:nil];
        } else {
            // Password is wrong, shake window and clear field
            [self shakeWindow];
            [passwordField setStringValue:@""];
            [self updateOKButtonState];
            [window makeFirstResponder:passwordField];
        }
    }
}

- (void)cancelClicked:(id)sender
{
    cancelled = YES;
    [NSApp terminate:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    // Check if password is actually required before showing dialog
    [self checkPasswordRequiredAndShowDialog];
}

// Prevent any system alerts from appearing
- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    // Disable system alerts at the earliest possible moment
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

// Add method to suppress system alerts
- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    // Ensure our window is on top when we become active
    if (window) {
        [window makeKeyAndOrderFront:nil];
    }
}

// Handle application errors gracefully
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    return NSTerminateNow;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

- (void)dealloc
{
    [window release];
    [passwordField release];
    [promptLabel release];
    [okButton release];
    [cancelButton release];
    [detailsButton release];
    [commandLabel release];
    [commandScrollView release];
    [sudoCommand release];
    [super dealloc];
}

- (void)detailsClicked:(id)sender
{
    @try {
        detailsVisible = !detailsVisible;
        
        NSRect currentFrame = [window frame];
        NSRect newFrame;
        
        if (detailsVisible) {
            // Expand window to show details - make it taller to fit command area
            newFrame = NSMakeRect(currentFrame.origin.x, currentFrame.origin.y - 132, 400, 282);
            [detailsButton setTitle:@"Hide Details"];
            
            [promptLabel setFrame:NSMakeRect(24, 222, 352, 20)];  // 40px from top
            [passwordField setFrame:NSMakeRect(24, 192, 352, 22)]; // 68px from top
            [commandScrollView setFrame:NSMakeRect(24, 54, 352, 130)];
            [commandScrollView setHidden:NO];
            
            // Buttons stay at bottom
            [detailsButton setFrame:NSMakeRect(24, 20, 80, 24)];
            [cancelButton setFrame:NSMakeRect(204, 20, 80, 24)];
            [okButton setFrame:NSMakeRect(296, 20, 80, 24)];
        } else {
            // Collapse window to hide details - RESET to EXACT original compact positions
            newFrame = NSMakeRect(currentFrame.origin.x, currentFrame.origin.y + 132, 400, 150);
            [detailsButton setTitle:@"Details"];
            
            // CRITICAL: Reset to EXACT original compact view positions as in showPasswordDialog
            [promptLabel setFrame:NSMakeRect(24, 90, 352, 20)];  // EXACT original position
            [passwordField setFrame:NSMakeRect(24, 60, 352, 22)]; // EXACT original position
            [commandScrollView setHidden:YES];
            
            // Reset buttons to EXACT original positions
            [detailsButton setFrame:NSMakeRect(24, 20, 80, 24)];
            [cancelButton setFrame:NSMakeRect(204, 20, 80, 24)];
            [okButton setFrame:NSMakeRect(296, 20, 80, 24)];
        }
        
        [window setFrame:newFrame display:YES animate:YES];
    }
    @catch (NSException *exception) {
        // If animation fails, just ignore it
    }
}

- (void)checkPasswordRequiredAndShowDialog
{
    // Run sudo -Nnv to check if password is required
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    
    [task setLaunchPath:@"sudo"]; // Do not use full path, just find on the PATH
    [task setArguments:[NSArray arrayWithObjects:@"-Nnv", nil]];
    [task setStandardOutput:pipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        // Read the output from stderr (where sudo outputs its messages)
        NSFileHandle *errorHandle = [errorPipe fileHandleForReading];
        NSData *errorData = [errorHandle readDataToEndOfFile];
        NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        // Check if the output contains "a password is required"
        if (errorOutput && [errorOutput rangeOfString:@"a password is required"].location != NSNotFound) {
            // Password is required, show the dialog
            [self showPasswordDialog];
        } else {
            // Password not required, exit successfully
            [NSApp terminate:nil];
        }
        
        [errorOutput release];
    }
    @catch (NSException *exception) {
        // If the check fails, show the dialog anyway to be safe
        [self showPasswordDialog];
    }
    @finally {
        [task release];
    }
}

- (BOOL)validatePassword:(NSString *)password
{
    // Create a task to validate the password using sudo -k followed by sudo -nv
    // First, clear any cached credentials
    NSTask *clearTask = [[NSTask alloc] init];
    [clearTask setLaunchPath:@"sudo"];
    [clearTask setArguments:[NSArray arrayWithObjects:@"-k", nil]];
    
    @try {
        [clearTask launch];
        [clearTask waitUntilExit];
    }
    @catch (NSException *exception) {
        // Ignore clear cache failures
    }
    @finally {
        [clearTask release];
    }
    
    // Now test the password using echo and sudo
    NSTask *task = [[NSTask alloc] init];
    NSPipe *inputPipe = [NSPipe pipe];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    
    [task setLaunchPath:@"sudo"];
    [task setArguments:[NSArray arrayWithObjects:@"-Sp", @"", @"true", nil]];
    [task setStandardInput:inputPipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    BOOL isValid = NO;
    
    @try {
        [task launch];
        
        // Send password to sudo
        NSFileHandle *inputHandle = [inputPipe fileHandleForWriting];
        NSData *passwordData = [[NSString stringWithFormat:@"%@\n", password] dataUsingEncoding:NSUTF8StringEncoding];
        [inputHandle writeData:passwordData];
        [inputHandle closeFile];
        
        [task waitUntilExit];
        
        // Check exit status - 0 means password was correct
        int exitStatus = [task terminationStatus];
        isValid = (exitStatus == 0);
    }
    @catch (NSException *exception) {
        isValid = NO;
    }
    @finally {
        [task release];
    }
    
    return isValid;
}

- (void)shakeWindow
{
    NSRect originalFrame = [window frame];
    NSRect shakeFrame = originalFrame;
    
    // Create a shake animation by moving the window left and right
    for (int i = 0; i < 6; i++) {
        // Move window 10 pixels to the right, then left
        shakeFrame.origin.x = originalFrame.origin.x + ((i % 2 == 0) ? 10 : -10);
        [window setFrame:shakeFrame display:YES];
        
        // Small delay between shake movements
        usleep(50000); // 50ms delay
        
        // Process events to ensure smooth animation
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    
    // Return to original position
    [window setFrame:originalFrame display:YES];
}

- (void)updateOKButtonState
{
    NSString *password = [passwordField stringValue];
    BOOL hasPassword = (password && [password length] > 0);
    [okButton setEnabled:hasPassword];
}

// NSTextField delegate method to monitor text changes
- (void)controlTextDidChange:(NSNotification *)notification
{
    if ([notification object] == passwordField) {
        [self updateOKButtonState];
    }
}

@end

int main(int argc, const char * argv[])
{
    // Redirect stderr IMMEDIATELY before any Objective-C code
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull != -1) {
        dup2(devnull, STDERR_FILENO);
        close(devnull);
    }
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Get the shared application instance and cast it
    NSApplication *app = [NSApplication sharedApplication];
    
    // Create controller immediately
    SudoAskPassController *controller = [[SudoAskPassController alloc] init];
    
    // Set delegate
    [app setDelegate:controller];
    
    // Force activation and run
    [app activateIgnoringOtherApps:YES];
    [app run];
    
    [controller release];
    [pool drain];
    
    return 0;
}
