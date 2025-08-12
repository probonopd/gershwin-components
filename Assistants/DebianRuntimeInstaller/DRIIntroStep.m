//
// DRIIntroStep.m
// Debian Runtime Installer - Introduction Step
//

#import "DRIIntroStep.h"

@implementation DRIIntroStep

- (NSString *)stepTitle
{
    return NSLocalizedString(@"Welcome to Debian Runtime Installer", @"");
}

- (NSString *)stepDescription
{
    return NSLocalizedString(@"Install a Debian runtime environment for FreeBSD", @"");
}

- (NSView *)stepView
{
    if (_contentView) {
        return _contentView;
    }

    NSLog(@"DRIIntroStep: creating stepView");

    // Match installer card inner area (approx 354x204)
    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];

    // Intro text inside the card (framework displays title/description outside)
    NSTextField *intro1 = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 148, 322, 36)];
    [intro1 setStringValue:NSLocalizedString(@"This assistant will install a Debian runtime environment on FreeBSD.", @"")];
    [intro1 setFont:[NSFont systemFontOfSize:12]];
    [intro1 setBezeled:NO];
    [intro1 setDrawsBackground:NO];
    [intro1 setEditable:NO];
    [intro1 setSelectable:NO];
    [[intro1 cell] setWraps:YES];
    [_contentView addSubview:intro1];
    [intro1 release];

    NSTextField *intro2 = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 110, 322, 48)];
    [intro2 setStringValue:NSLocalizedString(@"The Debian runtime enables running Linux applications via the compatibility layer.", @"")];
    [intro2 setFont:[NSFont systemFontOfSize:12]];
    [intro2 setBezeled:NO];
    [intro2 setDrawsBackground:NO];
    [intro2 setEditable:NO];
    [intro2 setSelectable:NO];
    [[intro2 cell] setWraps:YES];
    [_contentView addSubview:intro2];
    [intro2 release];

    // Checks summary
    NSTextField *reqLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 64, 322, 16)];
    BOOL isFreeBSD = [self checkFreeBSDSystem];
    [reqLabel setStringValue:isFreeBSD ? @"✓ FreeBSD system detected" : @"⚠ FreeBSD system not detected"];
    [reqLabel setBezeled:NO];
    [reqLabel setDrawsBackground:NO];
    [reqLabel setEditable:NO];
    [reqLabel setSelectable:NO];
    [reqLabel setTextColor:isFreeBSD ? [NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] : [NSColor colorWithDeviceRed:0.8 green:0.4 blue:0.0 alpha:1.0]];
    [_contentView addSubview:reqLabel];
    [reqLabel release];

    NSTextField *netLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 44, 306, 16)];
    BOOL hasNet = [self checkNetworkConnection];
    [netLabel setStringValue:hasNet ? @"✓ Network connection available" : @"⚠ No network connection detected"];
    [netLabel setBezeled:NO];
    [netLabel setDrawsBackground:NO];
    [netLabel setEditable:NO];
    [netLabel setSelectable:NO];
    [netLabel setTextColor:hasNet ? [NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] : [NSColor colorWithDeviceRed:0.8 green:0.4 blue:0.0 alpha:1.0]];
    [_contentView addSubview:netLabel];
    [netLabel release];

    NSTextField *spaceLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 24, 306, 16)];
    BOOL hasSpace = [self checkDiskSpace];
    [spaceLabel setStringValue:hasSpace ? @"✓ Sufficient disk space available" : @"⚠ Low disk space warning"];
    [spaceLabel setBezeled:NO];
    [spaceLabel setDrawsBackground:NO];
    [spaceLabel setEditable:NO];
    [spaceLabel setSelectable:NO];
    [spaceLabel setTextColor:hasSpace ? [NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0] : [NSColor colorWithDeviceRed:0.8 green:0.4 blue:0.0 alpha:1.0]];
    [_contentView addSubview:spaceLabel];
    [spaceLabel release];

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
