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
    
    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)];
    
    // Status icon
    _statusIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(220, 220, 48, 48)];
    [self updateStatusIcon];
    [_contentView addSubview:_statusIcon];
    
    // Status label
    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 180, 440, 24)];
    [_statusLabel setStringValue:_installationSuccessful ? 
                                 @"Debian Runtime Installed Successfully" : 
                                 @"Installation Failed"];
    [_statusLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setAlignment:NSTextAlignmentCenter];
    [_statusLabel setTextColor:_installationSuccessful ? 
                               [NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] :
                               [NSColor colorWithDeviceRed:0.8 green:0.0 blue:0.0 alpha:1.0]];
    [_contentView addSubview:_statusLabel];
    
    // Next steps view
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 40, 440, 130)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];
    
    _nextStepsView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 130)];
    [_nextStepsView setEditable:NO];
    [_nextStepsView setDrawsBackground:NO];
    [_nextStepsView setFont:[NSFont systemFontOfSize:12]];
    [self updateNextStepsText];
    
    [scrollView setDocumentView:_nextStepsView];
    [_contentView addSubview:scrollView];
    
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
    return @"Done";
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
    _completionMessage = message ?: (_installationSuccessful ? @"Installation completed successfully." : @"Installation failed.");
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
    NSImage *statusImage = [[NSImage alloc] initWithSize:NSMakeSize(48, 48)];
    [statusImage lockFocus];
    
    if (_installationSuccessful) {
        // Draw a green checkmark
        [[NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] setFill];
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 48, 48)];
        [circle fill];
        
        [[NSColor whiteColor] setStroke];
        NSBezierPath *checkmark = [NSBezierPath bezierPath];
        [checkmark setLineWidth:4.0];
        [checkmark moveToPoint:NSMakePoint(12, 24)];
        [checkmark lineToPoint:NSMakePoint(20, 16)];
        [checkmark lineToPoint:NSMakePoint(36, 32)];
        [checkmark stroke];
    } else {
        // Draw a red X
        [[NSColor colorWithDeviceRed:0.8 green:0.0 blue:0.0 alpha:1.0] setFill];
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 48, 48)];
        [circle fill];
        
        [[NSColor whiteColor] setStroke];
        NSBezierPath *x = [NSBezierPath bezierPath];
        [x setLineWidth:4.0];
        [x moveToPoint:NSMakePoint(12, 12)];
        [x lineToPoint:NSMakePoint(36, 36)];
        [x moveToPoint:NSMakePoint(36, 12)];
        [x lineToPoint:NSMakePoint(12, 36)];
        [x stroke];
    }
    
    [statusImage unlockFocus];
    [_statusIcon setImage:statusImage];
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
