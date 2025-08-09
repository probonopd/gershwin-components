//
// DRIIntroStep.m
// Debian Runtime Installer - Introduction Step
//

#import "DRIIntroStep.h"

@implementation DRIIntroStep

- (NSString *)stepTitle
{
    return @"Welcome to Debian Runtime Installer";
}

- (NSString *)stepDescription
{
    return @"Install a Debian runtime environment for FreeBSD";
}

- (NSView *)stepView
{
    if (_contentView) {
        return _contentView;
    }
    
    NSLog(@"DRIIntroStep: creating stepView");
    
    // Main content view
    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)];
    
    // Title
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 440, 24)];
    [titleLabel setStringValue:@"Install Debian Runtime"];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:18]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [_contentView addSubview:titleLabel];
    
    // Description
    NSTextView *descriptionView = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 120, 440, 150)];
    [descriptionView setString:@"This assistant will help you install a Debian runtime environment on your FreeBSD system.\n\nThe Debian runtime allows you to run Linux applications and provides compatibility for software that requires a Linux environment.\n\nThis installation requires administrator privileges and will create a runtime image at /compat/debian.img.\n\nFeatures:\n• Downloads runtime images from GitHub releases\n• Supports custom image URLs\n• Configures Linux compatibility layer\n• Sets up automatic service startup"];
    [descriptionView setEditable:NO];
    [descriptionView setDrawsBackground:NO];
    [descriptionView setFont:[NSFont systemFontOfSize:12]];
    [_contentView addSubview:descriptionView];
    
    // Requirements check
    NSTextField *reqLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 80, 440, 16)];
    [reqLabel setStringValue:[self checkFreeBSDSystem] ? @"✓ FreeBSD system detected" : @"⚠ FreeBSD system not detected"];
    [reqLabel setBezeled:NO];
    [reqLabel setDrawsBackground:NO];
    [reqLabel setEditable:NO];
    [reqLabel setSelectable:NO];
    [reqLabel setTextColor:[self checkFreeBSDSystem] ? 
                           [NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] :
                           [NSColor colorWithDeviceRed:0.8 green:0.4 blue:0.0 alpha:1.0]];
    [_contentView addSubview:reqLabel];
    
    NSTextField *netLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 60, 440, 16)];
    [netLabel setStringValue:[self checkNetworkConnection] ? @"✓ Internet connection available" : @"⚠ Internet connection check failed"];
    [netLabel setBezeled:NO];
    [netLabel setDrawsBackground:NO];
    [netLabel setEditable:NO];
    [netLabel setSelectable:NO];
    [netLabel setTextColor:[self checkNetworkConnection] ? 
                           [NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] :
                           [NSColor colorWithDeviceRed:0.8 green:0.4 blue:0.0 alpha:1.0]];
    [_contentView addSubview:netLabel];
    
    NSTextField *spaceLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 40, 440, 16)];
    [spaceLabel setStringValue:[self checkDiskSpace] ? @"✓ Sufficient disk space available" : @"⚠ Low disk space warning"];
    [spaceLabel setBezeled:NO];
    [spaceLabel setDrawsBackground:NO];
    [spaceLabel setEditable:NO];
    [spaceLabel setSelectable:NO];
    [spaceLabel setTextColor:[self checkDiskSpace] ? 
                             [NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] :
                             [NSColor colorWithDeviceRed:0.8 green:0.4 blue:0.0 alpha:1.0]];
    [_contentView addSubview:spaceLabel];
    
    return _contentView;
}

- (BOOL)canContinue
{
    return YES; // Allow continue even with warnings
}

- (BOOL)canGoBack
{
    return NO; // This is the first step
}

- (void)stepWillAppear
{
    NSLog(@"DRIIntroStep: stepWillAppear");
}

- (void)stepDidAppear
{
    NSLog(@"DRIIntroStep: stepDidAppear");
}

#pragma mark - System Checks

- (BOOL)checkFreeBSDSystem
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/uname"];
    [task setArguments:@[@"-s"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        output = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        BOOL isFreeBSD = [output isEqualToString:@"FreeBSD"];
        NSLog(@"DRIIntroStep: system check - uname -s returned: %@ (FreeBSD: %@)", output, isFreeBSD ? @"YES" : @"NO");
        return isFreeBSD;
        
    } @catch (NSException *exception) {
        NSLog(@"DRIIntroStep: system check failed: %@", exception.reason);
        return NO;
    }
}

- (BOOL)checkNetworkConnection
{
    // Simple network check - try to resolve a known host
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/host"];
    [task setArguments:@[@"github.com"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    
    @try {
        [task launch];
        
        // Set a timeout using a timer
        NSTimer *timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                                  target:self
                                                                selector:@selector(timeoutNetworkCheck:)
                                                                userInfo:task
                                                                 repeats:NO];
        
        [task waitUntilExit];
        [timeoutTimer invalidate];
        
        BOOL hasNetwork = ([task terminationStatus] == 0);
        NSLog(@"DRIIntroStep: network check - host github.com returned status %d (connected: %@)", 
              [task terminationStatus], hasNetwork ? @"YES" : @"NO");
        return hasNetwork;
        
    } @catch (NSException *exception) {
        NSLog(@"DRIIntroStep: network check failed: %@", [exception reason]);
        return NO;
    }
}

- (void)timeoutNetworkCheck:(NSTimer *)timer
{
    NSTask *task = [timer userInfo];
    if ([task isRunning]) {
        NSLog(@"DRIIntroStep: network check timed out");
        [task terminate];
    }
}

- (BOOL)checkDiskSpace
{
    // Check available space in /compat or root filesystem
    NSString *checkPath = @"/compat";
    if (![[NSFileManager defaultManager] fileExistsAtPath:checkPath]) {
        checkPath = @"/";
    }
    
    NSError *error;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:checkPath error:&error];
    
    if (error) {
        NSLog(@"DRIIntroStep: disk space check failed: %@", error.localizedDescription);
        return NO;
    }
    
    NSNumber *freeSize = attributes[NSFileSystemFreeSize];
    long long freeBytesLL = [freeSize longLongValue];
    long long requiredBytes = 1024 * 1024 * 1024; // 1GB minimum
    
    BOOL hasSpace = (freeBytesLL >= requiredBytes);
    NSLog(@"DRIIntroStep: disk space check - free: %lld bytes, required: %lld bytes (sufficient: %@)", 
          freeBytesLL, requiredBytes, hasSpace ? @"YES" : @"NO");
    
    return hasSpace;
}

@end
