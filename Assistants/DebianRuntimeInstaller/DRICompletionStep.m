//
// DRICompletionStep.m
// Debian Runtime Installer - Completion Step
//

#import "DRICompletionStep.h"

@interface DRICompletionStep()
@property (nonatomic, assign) BOOL installationSuccessful;
@property (nonatomic, strong) NSString *completionMessage;
@end

@implementation DRICompletionStep

- (instancetype)init
{
    if (self = [super init]) {
        NSLog(@"DRICompletionStep: init");
        _installationSuccessful = YES; // Default to success
        _completionMessage = @"Installation completed successfully.";
    }
    return self;
}

- (void)dealloc
{
    if (_contentView) { [_contentView release]; _contentView = nil; }
    if (_statusIcon) { [_statusIcon release]; _statusIcon = nil; }
    if (_statusLabel) { [_statusLabel release]; _statusLabel = nil; }
    if (_nextStepsView) { [_nextStepsView release]; _nextStepsView = nil; }
    if (_completionMessage) { [_completionMessage release]; _completionMessage = nil; }
    [super dealloc];
}

- (NSString *)stepTitle
{
    return _installationSuccessful ? @"Installation Complete" : @"Installation Failed";
}

- (NSString *)stepDescription
{
    return _installationSuccessful ? 
           @"Debian runtime has been installed successfully" :
           @"Installation encountered an error";
}

- (NSView *)stepView
{
    if (_contentView) {
        return _contentView;
    }
    
    NSLog(@"DRICompletionStep: creating stepView");
    
    // Size within installer card (354x204)
    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    
    // Status icon (top center)
    _statusIcon = [[NSImageView alloc] initWithFrame:NSMakeRect((354-40)/2, 152, 40, 40)];
    [self updateStatusIcon];
    [_contentView addSubview:_statusIcon];
    
    // Status label (centered)
    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 128, 330, 18)];
    [_statusLabel setStringValue:_installationSuccessful ? 
                                 @"Debian Runtime Installed Successfully" : 
                                 @"Installation Failed"];
    [_statusLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setAlignment:NSTextAlignmentCenter];
    [_statusLabel setTextColor:_installationSuccessful ? 
                               [NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] :
                               [NSColor colorWithDeviceRed:0.8 green:0.0 blue:0.0 alpha:1.0]];
    [_contentView addSubview:_statusLabel];
    
    // Next steps / message (scrollable), compact
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 12, 330, 108)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];
    
    _nextStepsView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 310, 108)];
    [_nextStepsView setEditable:NO];
    [_nextStepsView setDrawsBackground:NO];
    [_nextStepsView setFont:[NSFont systemFontOfSize:11]];
    [self updateNextStepsText];
    
    [scrollView setDocumentView:_nextStepsView];
    [_contentView addSubview:scrollView];
    [scrollView release];
    
    return _contentView;
}

- (BOOL)canContinue
{
    return NO;
}

- (BOOL)canGoBack
{
    return !_installationSuccessful; // Allow going back only if installation failed
}

- (NSString *)finishButtonTitle
{
    return NSLocalizedString(@"Done", @"");
}

- (void)stepWillAppear
{
    NSLog(@"DRICompletionStep: stepWillAppear (success: %@)", _installationSuccessful ? @"YES" : @"NO");
    [self updateUI];
}

- (void)stepDidAppear
{
    NSLog(@"DRICompletionStep: stepDidAppear");
}

- (void)setInstallationSuccessful:(BOOL)successful withMessage:(NSString *)message
{
    NSLog(@"DRICompletionStep: setInstallationSuccessful: %@ message: %@", successful ? @"YES" : @"NO", message);
    _installationSuccessful = successful;
    if (_completionMessage) { [_completionMessage release]; }
    _completionMessage = [message ? message : (_installationSuccessful ? @"Installation completed successfully." : @"Installation failed.") copy];
    [self updateUI];
}

- (void)updateUI
{
    if (!_contentView) {
        return; // UI not created yet
    }
    
    [self updateStatusIcon];
    
    [_statusLabel setStringValue:_installationSuccessful ? 
                                 @"Debian Runtime Installed Successfully" : 
                                 @"Installation Failed"];
    [_statusLabel setTextColor:_installationSuccessful ? 
                               [NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] :
                               [NSColor colorWithDeviceRed:0.8 green:0.0 blue:0.0 alpha:1.0]];
    
    [self updateNextStepsText];
}

- (void)updateStatusIcon
{
    if (!_statusIcon) {
        return;
    }
    
    // Create a simple status image programmatically since we may not have image resources
    NSImage *statusImage = [[NSImage alloc] initWithSize:NSMakeSize(40, 40)];
    [statusImage lockFocus];
    
    if (_installationSuccessful) {
        // Draw a green checkmark
        [[NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] setFill];
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 40, 40)];
        [circle fill];
        
        [[NSColor whiteColor] setStroke];
        NSBezierPath *checkmark = [NSBezierPath bezierPath];
        [checkmark setLineWidth:3.0];
        [checkmark moveToPoint:NSMakePoint(10, 20)];
        [checkmark lineToPoint:NSMakePoint(16, 14)];
        [checkmark lineToPoint:NSMakePoint(30, 26)];
        [checkmark stroke];
    } else {
        // Draw a red X
        [[NSColor colorWithDeviceRed:0.8 green:0.0 blue:0.0 alpha:1.0] setFill];
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 40, 40)];
        [circle fill];
        
        [[NSColor whiteColor] setStroke];
        NSBezierPath *x = [NSBezierPath bezierPath];
        [x setLineWidth:3.0];
        [x moveToPoint:NSMakePoint(10, 10)];
        [x lineToPoint:NSMakePoint(30, 30)];
        [x moveToPoint:NSMakePoint(30, 10)];
        [x lineToPoint:NSMakePoint(10, 30)];
        [x stroke];
    }
    
    [statusImage unlockFocus];
    [_statusIcon setImage:statusImage];
    [statusImage release];
}

- (void)updateNextStepsText
{
    if (!_nextStepsView) {
        return;
    }
    
    NSString *nextStepsText;
    
    if (_installationSuccessful) {
        nextStepsText = @"The Debian runtime has been installed successfully!\n\n"
                       @"What was installed:\n"
                       @"• Runtime image at /compat/debian.img\n"
                       @"• Service script at /usr/local/etc/rc.d/debian\n"
                       @"• Automatic startup configuration\n\n"
                       @"You can now:\n"
                       @"• Run Linux applications using the runtime\n"
                       @"• Start/stop the service with 'service debian start/stop'\n"
                       @"• Access the runtime environment at /compat/debian\n"
                       @"• Configure additional Linux software as needed\n\n"
                       @"The service will start automatically on system boot.\n\n"
                       @"For troubleshooting and more information, see the documentation.";
    } else {
        nextStepsText = [NSString stringWithFormat:@"Installation failed: %@\n\n"
                        @"Possible solutions:\n"
                        @"• Check your internet connection\n"
                        @"• Verify the application is running with root privileges\n"
                        @"• Ensure sufficient disk space is available\n"
                        @"• Try using a different runtime image URL\n"
                        @"• Check system logs for more details\n\n"
                        @"You can go back and try again with different settings.\n\n"
                        @"If the problem persists, please check the documentation or contact support.",
                        _completionMessage];
    }
    
    [_nextStepsView setString:nextStepsText];
}

@end
