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

@interface SudoAskPassController : NSObject
{
    NSWindow *window;
    NSSecureTextField *passwordField;
    NSTextField *promptLabel;
    NSButton *okButton;
    NSButton *cancelButton;
    NSButton *detailsButton;
    NSTextField *commandLabel;
    NSScrollView *commandScrollView;
    BOOL cancelled;
    BOOL detailsVisible;
}

- (void)showPasswordDialog;
- (void)checkPasswordRequiredAndShowDialog;
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
    // Get the command from environment variable
    NSString *sudoCommand = [[[NSProcessInfo processInfo] environment] objectForKey:@"SUDO_COMMAND"];
    
    if (!sudoCommand || [sudoCommand length] == 0) {
        // Try alternative environment variable names that might be used
        sudoCommand = [[[NSProcessInfo processInfo] environment] objectForKey:@"SUDO_COMMAND_LINE"];
        if (!sudoCommand || [sudoCommand length] == 0) {
            // Check command line arguments as fallback
            NSArray *args = [[NSProcessInfo processInfo] arguments];
            if ([args count] > 1) {
                sudoCommand = [NSString stringWithFormat:@"Arguments: %@", [args componentsJoinedByString:@" "]];
            } else {
                sudoCommand = @"(command not available - SUDO_COMMAND not set)";
            }
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
    
    [window setTitle:@"Sudo Password"];
    [window center];
    [window setLevel:NSFloatingWindowLevel]; // Keep window on top
    
    // Disable system beeps and alerts for this window
    [window setHidesOnDeactivate:NO];
    
    // Create prompt label
    NSRect promptRect = NSMakeRect(20, 90, 360, 30);
    promptLabel = [[NSTextField alloc] initWithFrame:promptRect];
    [promptLabel setStringValue:@"Enter your password for sudo:"];
    [promptLabel setBezeled:NO];
    [promptLabel setDrawsBackground:NO];
    [promptLabel setEditable:NO];  // Fix: should not be editable
    [promptLabel setSelectable:NO]; // Fix: should not be selectable
    [[window contentView] addSubview:promptLabel];
    
    // Create password field
    NSRect passwordRect = NSMakeRect(20, 60, 360, 22);
    passwordField = [[NSSecureTextField alloc] initWithFrame:passwordRect];
    [[window contentView] addSubview:passwordField];
    
    // Create Details button
    NSRect detailsRect = NSMakeRect(20, 20, 80, 30);
    detailsButton = [[NSButton alloc] initWithFrame:detailsRect];
    [detailsButton setTitle:@"Details"];
    [detailsButton setTarget:self];
    [detailsButton setAction:@selector(detailsClicked:)];
    [[window contentView] addSubview:detailsButton];
    
    // Create Cancel button
    NSRect cancelRect = NSMakeRect(220, 20, 80, 30);
    cancelButton = [[NSButton alloc] initWithFrame:cancelRect];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(cancelClicked:)];
    [cancelButton setKeyEquivalent:@"\033"];
    [[window contentView] addSubview:cancelButton];
    
    // Create OK button
    NSRect okRect = NSMakeRect(310, 20, 80, 30);
    okButton = [[NSButton alloc] initWithFrame:okRect];
    [okButton setTitle:@"OK"];
    [okButton setTarget:self];
    [okButton setAction:@selector(okClicked:)];
    [okButton setKeyEquivalent:@"\r"];
    [[window contentView] addSubview:okButton];
    
    // Create command details (initially hidden)
    NSRect commandRect = NSMakeRect(20, 55, 360, 60);
    commandScrollView = [[NSScrollView alloc] initWithFrame:commandRect];
    [commandScrollView setHasVerticalScroller:YES];
    [commandScrollView setHasHorizontalScroller:YES];
    [commandScrollView setAutohidesScrollers:YES];
    [commandScrollView setBorderType:NSBezelBorder];
    [commandScrollView setHidden:YES];
    
    NSSize contentSize = [commandScrollView contentSize];
    commandLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    [commandLabel setStringValue:[NSString stringWithFormat:@"Command: %@", sudoCommand]];
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
    @try {
        NSString *password = [passwordField stringValue];
        if (password && [password length] > 0) {
            printf("%s\n", [password UTF8String]);
            fflush(stdout);
        }
    }
    @catch (NSException *exception) {
        // If password output fails, still terminate
    }
    [NSApp terminate:nil];
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
    [super dealloc];
}

- (void)detailsClicked:(id)sender
{
    @try {
        detailsVisible = !detailsVisible;
        
        NSRect currentFrame = [window frame];
        NSRect newFrame;
        
        if (detailsVisible) {
            // Expand window to show details
            newFrame = NSMakeRect(currentFrame.origin.x, currentFrame.origin.y - 80, 400, 230);
            [detailsButton setTitle:@"Hide Details"];
            
            // Adjust positions for expanded view - password field moves down
            [passwordField setFrame:NSMakeRect(20, 140, 360, 22)];
            [promptLabel setFrame:NSMakeRect(20, 170, 360, 30)];
            [commandScrollView setFrame:NSMakeRect(20, 55, 360, 80)];
            [commandScrollView setHidden:NO];
            
            // Buttons stay at bottom
            [detailsButton setFrame:NSMakeRect(20, 20, 80, 30)];
            [cancelButton setFrame:NSMakeRect(220, 20, 80, 30)];
            [okButton setFrame:NSMakeRect(310, 20, 80, 30)];
        } else {
            // Collapse window to hide details - RESET to original compact positions
            newFrame = NSMakeRect(currentFrame.origin.x, currentFrame.origin.y + 80, 400, 150);
            [detailsButton setTitle:@"Details"];
            
            // IMPORTANT: Reset to original compact view positions exactly as in showPasswordDialog
            [promptLabel setFrame:NSMakeRect(20, 90, 360, 30)];  // Original position
            [passwordField setFrame:NSMakeRect(20, 60, 360, 22)]; // Original position
            [commandScrollView setHidden:YES];
            
            // Reset buttons to original positions
            [detailsButton setFrame:NSMakeRect(20, 20, 80, 30)];
            [cancelButton setFrame:NSMakeRect(220, 20, 80, 30)];
            [okButton setFrame:NSMakeRect(310, 20, 80, 30)];
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
    
    [task setLaunchPath:@"/usr/bin/sudo"];
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
