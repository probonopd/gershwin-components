/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


//
// InstallationSteps.m
// Installation Assistant - Custom Step Classes
//

#import "InstallationSteps.h"

#import <sys/utsname.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

@protocol DockService
- (void)setProgressValue:(double)value;
- (void)setProgressVisible:(BOOL)visible;
@end

// ============================================================================
// Helper: Detect whether the real kernel is FreeBSD (even under Linux compat)
// ============================================================================
static BOOL IAIsFreeBSD(void)
{
    struct utsname u;
    if (uname(&u) == 0 && strcmp(u.sysname, "FreeBSD") == 0) {
        return YES;
    }
    /* uname may report "Linux" under FreeBSD Linux compatibility layer.
     * Detect real FreeBSD by checking for freebsd-version or /etc/rc.conf
     * combined with sysctl kern.ostype. */
    if (access("/bin/freebsd-version", X_OK) == 0) {
        NSDebugLLog(@"gwcomp", @"IAIsFreeBSD: detected FreeBSD via /bin/freebsd-version");
        return YES;
    }
    if (access("/etc/rc.conf", R_OK) == 0 && access("/sbin/sysctl", X_OK) == 0) {
        /* Double check with sysctl kern.ostype */
        FILE *fp = popen("sysctl -n kern.ostype 2>/dev/null", "r");
        if (fp) {
            char buf[64] = {0};
            if (fgets(buf, sizeof(buf), fp) != NULL) {
                /* Strip trailing newline */
                char *nl = strchr(buf, '\n');
                if (nl) *nl = '\0';
                if (strcmp(buf, "FreeBSD") == 0) {
                    pclose(fp);
                    NSDebugLLog(@"gwcomp", @"IAIsFreeBSD: detected FreeBSD via sysctl kern.ostype");
                    return YES;
                }
            }
            pclose(fp);
        }
    }
    return NO;
}

// ============================================================================
// Helper: Determine installer script path from app bundle
// ============================================================================
NSString *IAInstallerScriptPath(void)
{
    NSString *scriptName = IAIsFreeBSD() ? @"installer-FreeBSD" : @"installer-Linux";
    NSDebugLLog(@"gwcomp", @"IAInstallerScriptPath: selected script %@", scriptName);

    NSString *path = [[NSBundle mainBundle] pathForResource:scriptName ofType:@"sh"];
    if (!path) {
        NSDebugLLog(@"gwcomp", @"IAInstallerScriptPath: script %@.sh not found in bundle, searching in Resources/", scriptName);
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        path = [bundlePath stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Resources/%@.sh", scriptName]];
    }
    NSDebugLLog(@"gwcomp", @"IAInstallerScriptPath: using script at %@", path);
    return path;
}

// ============================================================================
// Helper: Synchronously check for image source availability
// Returns the mount path of the image source, or nil if none found.
// ============================================================================
NSString *IACheckImageSourceAvailable(void)
{
    NSString *scriptPath = IAInstallerScriptPath();
    NSDebugLLog(@"gwcomp", @"IACheckImageSourceAvailable: running %@ --check-image-source", scriptPath);

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:scriptPath];
    [task setArguments:@[@"--check-image-source"]];

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:errPipe];

    NSString *result = nil;
    @try {
        [task launch];
        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];

        NSString *outStr = outData ? [[[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] autorelease] : @"";
        NSDebugLLog(@"gwcomp", @"IACheckImageSourceAvailable: script output: %@", outStr);

        NSArray *lines = [outStr componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSString *line in lines) {
            if ([line hasPrefix:@"IMAGE_SOURCE:"]) {
                NSString *src = [line substringFromIndex:[@"IMAGE_SOURCE:" length]];
                src = [src stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([src length] > 0) {
                    result = src;
                }
                break;
            }
        }
    } @catch (NSException *ex) {
        NSDebugLLog(@"gwcomp", @"IACheckImageSourceAvailable: exception: %@", ex);
    }
    [task release];

    NSDebugLLog(@"gwcomp", @"IACheckImageSourceAvailable: result = %@", result ?: @"(none)");
    return result;
}

@implementation IADiskInfo
@synthesize devicePath, name, diskDescription, sizeBytes, formattedSize;
@end

@implementation IALicenseStep

@synthesize stepTitle, stepDescription;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = @"License Agreement";
        self.stepDescription = @"Please read and accept the software license";
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 250)];
    
    // License text view with scroll
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 50, 360, 180)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    
    _licenseTextView = [[NSTextView alloc] init];
    [_licenseTextView setEditable:NO];
    [_licenseTextView setString:@"BSD 2-Clause License\n\nCopyright (c) 2023, Gershwin Project\nAll rights reserved.\n\nRedistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:\n\n1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.\n\n2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.\n\nTHIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."];
    
    [scrollView setDocumentView:_licenseTextView];
    [_stepView addSubview:scrollView];
    [scrollView release];
    
    // Agreement checkbox
    _agreeCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(24, 20, 350, 20)];
    [_agreeCheckbox setButtonType:NSSwitchButton];
    [_agreeCheckbox setTitle:@"I agree to the terms and conditions of this license"];
    [_agreeCheckbox setState:NSOffState];
    [_agreeCheckbox setTarget:self];
    [_agreeCheckbox setAction:@selector(checkboxChanged:)];
    [_stepView addSubview:_agreeCheckbox];
}

- (void)checkboxChanged:(id)sender
{
    [self requestNavigationUpdate];
}

- (void)requestNavigationUpdate
{
    NSWindow *window = [[self stepView] window];
    if (!window) {
        window = [NSApp keyWindow];
    }
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        [assistantWindow updateNavigationButtons];
    }
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    return ([_agreeCheckbox state] == NSOnState);
}

- (BOOL)userAgreedToLicense
{
    return ([_agreeCheckbox state] == NSOnState);
}

@end

@implementation IADestinationStep

@synthesize stepTitle, stepDescription;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = @"Installation Location";
        self.stepDescription = @"Choose where to install the software";
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    
    // Destination selection
    NSTextField *destinationLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 160, 150, 20)];
    [destinationLabel setStringValue:NSLocalizedString(@"Install to:", @"")];
    [destinationLabel setBezeled:NO];
    [destinationLabel setDrawsBackground:NO];
    [destinationLabel setEditable:NO];
    [destinationLabel setSelectable:NO];
    [_stepView addSubview:destinationLabel];
    [destinationLabel release];
    
    _destinationPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 130, 300, 24)];
    [_destinationPopup addItemWithTitle:@"/usr/local"];
    [_destinationPopup addItemWithTitle:@"/opt/gershwin"];
    [_destinationPopup addItemWithTitle:NSLocalizedString(@"Choose...", @"")];
    [_stepView addSubview:_destinationPopup];
    
    // Space requirements
    _spaceRequiredLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 90, 350, 20)];
    [_spaceRequiredLabel setStringValue:NSLocalizedString(@"Space required: 2.5 GB", @"")];
    [_spaceRequiredLabel setBezeled:NO];
    [_spaceRequiredLabel setDrawsBackground:NO];
    [_spaceRequiredLabel setEditable:NO];
    [_spaceRequiredLabel setSelectable:NO];
    [_stepView addSubview:_spaceRequiredLabel];
    
    _spaceAvailableLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 70, 350, 20)];
    [_spaceAvailableLabel setStringValue:NSLocalizedString(@"Space available: 15.2 GB", @"")];
    [_spaceAvailableLabel setBezeled:NO];
    [_spaceAvailableLabel setDrawsBackground:NO];
    [_spaceAvailableLabel setEditable:NO];
    [_spaceAvailableLabel setSelectable:NO];
    [_stepView addSubview:_spaceAvailableLabel];
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    // Always can continue - a destination is pre-selected
    return YES;
}

- (NSString *)selectedDestination
{
    return [_destinationPopup titleOfSelectedItem];
}

@end

@implementation IAOptionsStep

@synthesize stepTitle, stepDescription;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = @"Installation Options";
        self.stepDescription = @"Select components to install";
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    
    NSTextField *optionsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 170, 350, 20)];
    [optionsLabel setStringValue:NSLocalizedString(@"Choose optional components to install:", @"")];
    [optionsLabel setBezeled:NO];
    [optionsLabel setDrawsBackground:NO];
    [optionsLabel setEditable:NO];
    [optionsLabel setSelectable:NO];
    [_stepView addSubview:optionsLabel];
    [optionsLabel release];
    
    // Development Tools checkbox
    _installDevelopmentToolsCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 140, 350, 20)];
    [_installDevelopmentToolsCheckbox setButtonType:NSSwitchButton];
    [_installDevelopmentToolsCheckbox setTitle:@"Development Tools (GCC, Make, etc.)"];
    [_installDevelopmentToolsCheckbox setState:NSOnState]; // Default to checked
    [_stepView addSubview:_installDevelopmentToolsCheckbox];
    
    // Linux Compatibility checkbox
    _installLinuxCompatibilityCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 110, 350, 20)];
    [_installLinuxCompatibilityCheckbox setButtonType:NSSwitchButton];
    [_installLinuxCompatibilityCheckbox setTitle:@"Linux Compatibility Layer"];
    [_installLinuxCompatibilityCheckbox setState:NSOnState]; // Default to checked
    [_stepView addSubview:_installLinuxCompatibilityCheckbox];
    
    // Documentation checkbox
    _installDocumentationCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 80, 350, 20)];
    [_installDocumentationCheckbox setButtonType:NSSwitchButton];
    [_installDocumentationCheckbox setTitle:@"Documentation and Examples"];
    [_installDocumentationCheckbox setState:NSOnState]; // Default to checked
    [_stepView addSubview:_installDocumentationCheckbox];
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    // Always can continue - at least core components will be installed
    return YES;
}

- (BOOL)installDevelopmentTools
{
    return ([_installDevelopmentToolsCheckbox state] == NSOnState);
}

- (BOOL)installLinuxCompatibility
{
    return ([_installLinuxCompatibilityCheckbox state] == NSOnState);
}

- (BOOL)installDocumentation
{
    return ([_installDocumentationCheckbox state] == NSOnState);
}

@end

// ============================================================================
// IAWelcomeStep - simple welcome screen
// ============================================================================

@implementation IAWelcomeStep

@synthesize stepTitle, stepDescription;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Welcome", @"");
        self.stepDescription = NSLocalizedString(@"Welcome to the installer", @"");
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 140, 360, 40)];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setStringValue:NSLocalizedString(@"This assistant will guide you through installing the operating system.", @"")];
    [[label cell] setWraps:YES];
    [label setFont:[NSFont systemFontOfSize:12]];
    [_stepView addSubview:label];
    [label release];
}

- (NSView *)stepView
{
    return _stepView;
}

- (NSString *)stepTitle { return stepTitle; }
- (NSString *)stepDescription { return stepDescription; }
- (BOOL)canContinue { return YES; }

@end

// ============================================================================
// IAInstallTypeStep - Choose clone vs image-based installation
// ============================================================================

@implementation IAInstallTypeStep

@synthesize stepTitle, stepDescription, delegate;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Installation Type", @"");
        self.stepDescription = NSLocalizedString(@"Choose how to install the system", @"");
        _detectedImageSource = nil;
        _imageSourceAvailable = NO;
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [_detectedImageSource release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 160, 360, 20)];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setStringValue:NSLocalizedString(@"Choose the installation method:", @"")];
    [_stepView addSubview:label];
    [label release];

    _cloneRadio = [[NSButton alloc] initWithFrame:NSMakeRect(20, 126, 360, 24)];
    [_cloneRadio setButtonType:NSRadioButton];
    [_cloneRadio setTitle:NSLocalizedString(@"Clone running system to disk", @"")];
    [_cloneRadio setState:NSOnState];
    [_cloneRadio setTarget:self];
    [_cloneRadio setAction:@selector(radioChanged:)];
    [_stepView addSubview:_cloneRadio];

    _imageRadio = [[NSButton alloc] initWithFrame:NSMakeRect(20, 90, 360, 24)];
    [_imageRadio setButtonType:NSRadioButton];
    [_imageRadio setTitle:NSLocalizedString(@"Image based installation (from external media)", @"")];
    [_imageRadio setState:NSOffState];
    [_imageRadio setEnabled:NO];
    [_imageRadio setTarget:self];
    [_imageRadio setAction:@selector(radioChanged:)];
    [_stepView addSubview:_imageRadio];

    _imageSourceLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 62, 340, 20)];
    [_imageSourceLabel setBezeled:NO];
    [_imageSourceLabel setDrawsBackground:NO];
    [_imageSourceLabel setEditable:NO];
    [_imageSourceLabel setSelectable:NO];
    [_imageSourceLabel setTextColor:[NSColor grayColor]];
    [_imageSourceLabel setStringValue:NSLocalizedString(@"No installation media detected", @"")];
    [_stepView addSubview:_imageSourceLabel];
}

- (void)radioChanged:(id)sender
{
    if (sender == _cloneRadio) {
        [_cloneRadio setState:NSOnState];
        [_imageRadio setState:NSOffState];
    } else if (sender == _imageRadio) {
        [_imageRadio setState:NSOnState];
        [_cloneRadio setState:NSOffState];
    }
    if (delegate && [delegate respondsToSelector:@selector(installTypeStep:didSelectImageSource:)]) {
        [delegate installTypeStep:self didSelectImageSource:[self useImageInstall] ? _detectedImageSource : nil];
    }
}

- (void)detectImageSource
{
    /* Called externally if the caller already knows the image source path.
     * Alternatively runs the check script to detect it. */
    NSString *source = IACheckImageSourceAvailable();
    if (source && [source length] > 0) {
        [_detectedImageSource release];
        _detectedImageSource = [source copy];
        _imageSourceAvailable = YES;
        [_imageRadio setEnabled:YES];
        [_imageSourceLabel setStringValue:[NSString stringWithFormat:
            NSLocalizedString(@"Image source detected: %@", @""), _detectedImageSource]];
        [_imageSourceLabel setTextColor:[NSColor controlTextColor]];
        NSDebugLLog(@"gwcomp", @"IAInstallTypeStep: image source available at %@", _detectedImageSource);
    } else {
        _imageSourceAvailable = NO;
        [_imageRadio setEnabled:NO];
        [_imageSourceLabel setStringValue:NSLocalizedString(@"No installation media detected", @"")];
        [_imageSourceLabel setTextColor:[NSColor grayColor]];
        NSDebugLLog(@"gwcomp", @"IAInstallTypeStep: no image source available");
    }
}

- (void)setImageSource:(NSString *)sourcePath
{
    [_detectedImageSource release];
    _detectedImageSource = [sourcePath copy];
    if (_detectedImageSource && [_detectedImageSource length] > 0) {
        _imageSourceAvailable = YES;
        [_imageRadio setEnabled:YES];
        [_imageSourceLabel setStringValue:[NSString stringWithFormat:
            NSLocalizedString(@"Image source detected: %@", @""), _detectedImageSource]];
        [_imageSourceLabel setTextColor:[NSColor controlTextColor]];
    }
}

- (BOOL)useImageInstall
{
    return (_imageSourceAvailable && [_imageRadio state] == NSOnState);
}

- (NSString *)imageSourcePath
{
    if ([self useImageInstall]) {
        return _detectedImageSource;
    }
    return nil;
}

- (NSView *)stepView { return _stepView; }
- (NSString *)stepTitle { return stepTitle; }
- (NSString *)stepDescription { return stepDescription; }
- (BOOL)canContinue { return YES; }

@end

// ============================================================================
// IADiskSelectionStep - enumerates disks using external installer scripts
// ============================================================================

@implementation IADiskSelectionStep

@synthesize stepTitle, stepDescription, delegate;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Select Destination Disk", @"");
        self.stepDescription = NSLocalizedString(@"Choose a physical disk to install to", @"");
        _disks = [[NSMutableArray alloc] init];
        _diagnostics = [[NSMutableString alloc] init];
        [self setupView];
        /* Use performSelector:afterDelay: instead of dispatch_after on main queue
         * because GCD main queue is not integrated with the GNUstep NSRunLoop. */
        [self performSelector:@selector(refreshDiskList) withObject:nil afterDelay:0.5];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_stepView release];
    [_tableView release];
    [_disks release];
    [_statusLabel release];
    [_spinner release];
    [_diagnostics release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 240)];

    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 200, 360, 20)];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setStringValue:NSLocalizedString(@"Scanning for disks...", @"")];
    [_stepView addSubview:_statusLabel];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 60, 360, 130)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];

    _tableView = [[NSTableView alloc] initWithFrame:[[scrollView contentView] frame]];
    NSTableColumn *col1 = [[NSTableColumn alloc] initWithIdentifier:@"devicePath"]; [[col1 headerCell] setStringValue:NSLocalizedString(@"Device", @"")]; [col1 setWidth:120]; [_tableView addTableColumn:col1]; [col1 release];
    NSTableColumn *col2 = [[NSTableColumn alloc] initWithIdentifier:@"name"]; [[col2 headerCell] setStringValue:NSLocalizedString(@"Name", @"")]; [col2 setWidth:160]; [_tableView addTableColumn:col2]; [col2 release];
    NSTableColumn *col3 = [[NSTableColumn alloc] initWithIdentifier:@"formattedSize"]; [[col3 headerCell] setStringValue:NSLocalizedString(@"Size", @"")]; [col3 setWidth:70]; [_tableView addTableColumn:col3]; [col3 release];

    [_tableView setDelegate:(id<NSTableViewDelegate>)self];
    [_tableView setDataSource:(id<NSTableViewDataSource>)self];
    [scrollView setDocumentView:_tableView];
    [_stepView addSubview:scrollView];
    [scrollView release];

    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 20, 16, 16)];
    [_spinner setStyle:NSProgressIndicatorSpinningStyle];
    [_spinner startAnimation:nil];
    [_stepView addSubview:_spinner];
}

- (void)refreshDiskList
{
    NSDebugLLog(@"gwcomp", @"IADiskSelectionStep: refreshDiskList");
    [_diagnostics setString:@""];
    [_statusLabel setStringValue:NSLocalizedString(@"Scanning for disks...", @"")];
    [_spinner startAnimation:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *scriptPath = IAInstallerScriptPath();
        NSDebugLLog(@"gwcomp", @"IADiskSelectionStep: using script %@", scriptPath);
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:scriptPath];
        [task setArguments:@[@"--list-disks", @"--debug"]];

        NSPipe *outPipe = [NSPipe pipe];
        NSPipe *errPipe = [NSPipe pipe];
        [task setStandardOutput:outPipe];
        [task setStandardError:errPipe];

        @try {
            [task launch];
        } @catch (NSException *ex) {
            NSDictionary *info = @{@"error": [NSString stringWithFormat:@"Exception launching script: %@", ex]};
            [self performSelectorOnMainThread:@selector(_diskScanFailed:) withObject:info waitUntilDone:NO];
            [task release];
            return;
        }

        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        int term = [task terminationStatus];

        NSString *outStr = outData ? [[[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] autorelease] : @"";
        NSString *errStr = errData ? [[[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] autorelease] : @"";

        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        [result setObject:(outStr ?: @"") forKey:@"stdout"];
        [result setObject:(errStr ?: @"") forKey:@"stderr"];
        [result setObject:[NSNumber numberWithInt:term] forKey:@"exitCode"];
        if (outData) [result setObject:outData forKey:@"outData"];
        [self performSelectorOnMainThread:@selector(_diskScanCompleted:) withObject:result waitUntilDone:NO];

        [task release];
    });
}

/* Main-thread callback: disk scan failed to launch */
- (void)_diskScanFailed:(NSDictionary *)info
{
    [_spinner stopAnimation:nil];
    [_statusLabel setStringValue:NSLocalizedString(@"Failed to start disk enumeration script", @"")];
    [_diagnostics appendFormat:@"%@\n", [info objectForKey:@"error"]];
}

/* Main-thread callback: disk scan completed (possibly with errors) */
- (void)_diskScanCompleted:(NSDictionary *)info
{
    [_spinner stopAnimation:nil];

    NSString *outStr = [info objectForKey:@"stdout"];
    NSString *errStr = [info objectForKey:@"stderr"];
    NSData *outData = [info objectForKey:@"outData"];
    int term = [[info objectForKey:@"exitCode"] intValue];

    if (outStr && [outStr length] > 0 && outData) {
        NSError *jsonError = nil;
        id obj = nil;
        @try {
            obj = [NSJSONSerialization JSONObjectWithData:outData options:0 error:&jsonError];
        } @catch (NSException *ex) {
            obj = nil;
            [_diagnostics appendFormat:@"JSON parse exception: %@\n", ex];
        }

        if (obj && [obj isKindOfClass:[NSArray class]]) {
            [_disks removeAllObjects];
            for (NSDictionary *d in obj) {
                IADiskInfo *disk = [[IADiskInfo alloc] init];
                disk.devicePath = [d objectForKey:@"devicePath"] ?: @"";
                disk.name = [d objectForKey:@"name"] ?: @"";
                disk.diskDescription = [d objectForKey:@"description"] ?: @"";
                disk.sizeBytes = [[d objectForKey:@"sizeBytes"] unsignedLongLongValue];
                disk.formattedSize = [d objectForKey:@"formattedSize"] ?: @"";
                [_disks addObject:disk];
                [disk release];
            }
            [_statusLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Found %lu disk(s)", @""), (unsigned long)[_disks count]]];
            [_tableView reloadData];
            NSDebugLLog(@"gwcomp", @"IADiskSelectionStep: found %lu disk(s)", (unsigned long)[_disks count]);
        } else {
            [_diagnostics appendString:@"Unexpected JSON output from script\n"];
            if (jsonError) [_diagnostics appendFormat:@"JSON error: %@\n", [jsonError localizedDescription]];
            if (errStr && [errStr length] > 0) [_diagnostics appendFormat:@"Script stderr:\n%@\n", errStr];
            [_statusLabel setStringValue:NSLocalizedString(@"Error enumerating disks", @"")];
        }
    } else {
        [_diagnostics appendString:@"No output from disk enumeration script\n"];
        if (errStr && [errStr length] > 0) [_diagnostics appendFormat:@"Script stderr:\n%@\n", errStr];
        [_statusLabel setStringValue:NSLocalizedString(@"No disks found", @"")];
    }

    if (term != 0) {
        [_diagnostics appendFormat:@"Script exited with status %d\n", term];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)[_disks count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if ((NSUInteger)row >= [_disks count]) return @"";
    IADiskInfo *d = [_disks objectAtIndex:row];
    NSString *ident = [tableColumn identifier];
    if ([ident isEqualToString:@"devicePath"]) return d.devicePath;
    if ([ident isEqualToString:@"name"]) return d.name;
    if ([ident isEqualToString:@"formattedSize"]) return d.formattedSize;
    return @"";
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    NSInteger sel = [_tableView selectedRow];
    if (sel >= 0 && (NSUInteger)sel < [_disks count]) {
        IADiskInfo *d = [_disks objectAtIndex:sel];
        if (delegate && [delegate respondsToSelector:@selector(diskSelectionStep:didSelectDisk:)]) {
            [delegate diskSelectionStep:self didSelectDisk:d];
        }
    }
    /* Update the assistant navigation buttons so Continue reflects canContinue */
    NSWindow *window = [[self stepView] window];
    if (!window) window = [NSApp keyWindow];
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        [(GSAssistantWindow *)wc updateNavigationButtons];
    }
}

- (IADiskInfo *)selectedDisk
{
    NSInteger sel = [_tableView selectedRow];
    if (sel >= 0 && (NSUInteger)sel < [_disks count]) return [_disks objectAtIndex:sel];
    return nil;
}

- (void)showDiagnostics:(id)sender
{
    // Show a modal panel with diagnostics text
    NSWindow *panel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 360)
                                                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    [panel setTitle:NSLocalizedString(@"Disk Enumeration Diagnostics", @"")];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 10, 580, 320)];
    [scrollView setHasVerticalScroller:YES];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 560, 320)];
    [tv setEditable:NO];
    [tv setString:_diagnostics ?: @"No diagnostics available"]; 
    [scrollView setDocumentView:tv];
    [[panel contentView] addSubview:scrollView];

    NSWindow *win = [[self stepView] window];
    if (!win) win = [NSApp keyWindow];
    [NSApp runModalForWindow:panel];

    [tv release];
    [scrollView release];
    [panel release];
}

- (NSView *)stepView { return _stepView; }
- (NSString *)stepTitle { return stepTitle; }
- (NSString *)stepDescription { return stepDescription; }
- (BOOL)canContinue { return ([self selectedDisk] != nil); }

@end

// ============================================================================
// IAConfirmStep - simple confirmation before destructive action
// ============================================================================

@implementation IAConfirmStep

@synthesize stepTitle, stepDescription;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Confirmation", @"");
        self.stepDescription = NSLocalizedString(@"Finalize and start installation", @"");
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];

    _warningLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 120, 360, 60)];
    [_warningLabel setBezeled:NO];
    [_warningLabel setDrawsBackground:NO];
    [_warningLabel setEditable:NO];
    [_warningLabel setSelectable:NO];
    [_warningLabel setStringValue:NSLocalizedString(@"Warning: This will erase all data on the selected disk.", @"")];
    [[_warningLabel cell] setWraps:YES];
    [_stepView addSubview:_warningLabel];

    _confirmCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 90, 360, 20)];
    [_confirmCheckbox setButtonType:NSSwitchButton];
    [_confirmCheckbox setTitle:NSLocalizedString(@"I understand that all data will be erased", @"")];
    [_confirmCheckbox setState:NSOffState];
    [_confirmCheckbox setTarget:self];
    [_confirmCheckbox setAction:@selector(checkboxToggled:)];
    [_stepView addSubview:_confirmCheckbox];

    _diskInfoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 60, 360, 20)];
    [_diskInfoLabel setBezeled:NO];
    [_diskInfoLabel setDrawsBackground:NO];
    [_diskInfoLabel setEditable:NO];
    [_diskInfoLabel setSelectable:NO];
    [_stepView addSubview:_diskInfoLabel];
}

- (void)checkboxToggled:(id)sender
{
    NSWindow *window = [[self stepView] window];
    if (!window) window = [NSApp keyWindow];
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        [assistantWindow updateNavigationButtons];
    }
}

- (void)updateWithDisk:(IADiskInfo *)disk
{
    if (disk) {
        [_diskInfoLabel setStringValue:[NSString stringWithFormat:@"%@ (%@)", disk.devicePath, disk.formattedSize ? disk.formattedSize : @""]];
    } else {
        [_diskInfoLabel setStringValue:@""];
    }
}

- (NSView *)stepView { return _stepView; }
- (NSString *)stepTitle { return stepTitle; }
- (NSString *)stepDescription { return stepDescription; }
- (BOOL)canContinue { return ([_confirmCheckbox state] == NSOnState); }

@end

// ============================================================================
// IALogWindowController - Separate log window
// ============================================================================

@implementation IALogWindowController

- (instancetype)init
{
    NSRect screenFrame = [[NSScreen mainScreen] frame];
    CGFloat logHeight = screenFrame.size.height / 4.0;
    NSRect logFrame = NSMakeRect(screenFrame.origin.x,
                                  screenFrame.origin.y,
                                  screenFrame.size.width,
                                  logHeight);
    NSWindow *logWindow = [[NSWindow alloc]
        initWithContentRect:logFrame
                  styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                             NSResizableWindowMask | NSMiniaturizableWindowMask)
                    backing:NSBackingStoreBuffered
                      defer:YES];
    [logWindow setTitle:NSLocalizedString(@"Installer Log", @"")];
    [logWindow setMinSize:NSMakeSize(400, 100)];

    if (self = [super initWithWindow:logWindow]) {
        NSView *contentView = [logWindow contentView];
        NSRect frame = [contentView bounds];

        _scrollView = [[NSScrollView alloc] initWithFrame:frame];
        [_scrollView setHasVerticalScroller:YES];
        [_scrollView setHasHorizontalScroller:NO];
        [_scrollView setBorderType:NSNoBorder];
        [_scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        NSSize contentSize = [_scrollView contentSize];
        _logView = [[NSTextView alloc] initWithFrame:
            NSMakeRect(0, 0, contentSize.width, contentSize.height)];
        [_logView setMinSize:NSMakeSize(0.0, contentSize.height)];
        [_logView setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
        [_logView setVerticallyResizable:YES];
        [_logView setHorizontallyResizable:NO];
        [_logView setEditable:NO];
        [_logView setSelectable:YES];
        [_logView setFont:[NSFont userFixedPitchFontOfSize:10]];
        [_logView setTextColor:[NSColor darkGrayColor]];
        [_logView setBackgroundColor:[NSColor whiteColor]];
        [[_logView textContainer] setContainerSize:NSMakeSize(contentSize.width, FLT_MAX)];
        [[_logView textContainer] setWidthTracksTextView:YES];

        [_scrollView setDocumentView:_logView];
        [contentView addSubview:_scrollView];
    }
    [logWindow release];
    return self;
}

- (void)dealloc
{
    [_scrollView release];
    [_logView release];
    [super dealloc];
}

- (void)appendLog:(NSString *)text
{
    if (!text || !_logView) return;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont userFixedPitchFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor darkGrayColor]
    };
    NSAttributedString *astr = [[NSAttributedString alloc] initWithString:text
                                                               attributes:attrs];
    [[_logView textStorage] appendAttributedString:astr];
    [astr release];
    [_logView scrollRangeToVisible:NSMakeRange([[_logView string] length], 0)];
}

- (void)clearLog
{
    if (!_logView) return;
    [[_logView textStorage] replaceCharactersInRange:
        NSMakeRange(0, [[_logView string] length]) withString:@""];
}

@end

// ============================================================================
// IAInstallProgressStep - run installer script and parse PROGRESS lines
// ============================================================================

@implementation IAInstallProgressStep

@synthesize stepTitle, stepDescription, delegate;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Installing", @"");
        self.stepDescription = NSLocalizedString(@"Installing the system to the selected disk", @"");
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [((id<DockService>)_dockProxy) setProgressVisible:NO];
    [_etaTimer invalidate];
    [_etaTimer release];
    [_startTime release];
    [_stepView release];
    [_progressBar release];
    [_detailLabel release];
    [_etaLabel release];
    [_lineBuffer release];
    [_outputPipe release];
    [_installerTask release];
    [self setLogWindowController:nil];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 250)];

    /* Status detail label - above progress bar, shows current operation */
    _detailLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 141, 320, 18)];
    [_detailLabel setBezeled:NO]; [_detailLabel setDrawsBackground:NO];
    [_detailLabel setEditable:NO]; [_detailLabel setSelectable:NO];
    [_detailLabel setFont:[NSFont systemFontOfSize:11]];
    [_detailLabel setTextColor:[NSColor darkGrayColor]];
    [_detailLabel setAlignment:NSCenterTextAlignment];
    [_detailLabel setStringValue:NSLocalizedString(@"Preparing installation...", @"")];
    [_stepView addSubview:_detailLabel];

    /* Progress bar - vertically centered */
    _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(40, 117, 320, 16)];
    [_progressBar setIndeterminate:NO];
    [_progressBar setMinValue:0.0];
    [_progressBar setMaxValue:100.0];
    [_stepView addSubview:_progressBar];

    /* ETA label below progress bar */
    _etaLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 91, 320, 18)];
    [_etaLabel setBezeled:NO]; [_etaLabel setDrawsBackground:NO];
    [_etaLabel setEditable:NO]; [_etaLabel setSelectable:NO];
    [_etaLabel setFont:[NSFont systemFontOfSize:11]];
    [_etaLabel setTextColor:[NSColor grayColor]];
    [_etaLabel setAlignment:NSCenterTextAlignment];
    [_stepView addSubview:_etaLabel];

    _lineBuffer = [[NSMutableString alloc] init];
}

- (void)startInstallationToDisk:(IADiskInfo *)disk
{
    [self startInstallationToDisk:disk source:nil];
}

- (void)startInstallationToDisk:(IADiskInfo *)disk source:(NSString *)sourcePathOrNil
{
    if (!disk) {
        NSDebugLLog(@"gwcomp", @"IAInstallProgressStep: ERROR - no disk provided");
        return;
    }
    if (_isRunning) {
        NSDebugLLog(@"gwcomp", @"IAInstallProgressStep: already running, ignoring duplicate start");
        return;
    }

    // Connect to Dock DO service for progress bar in icon
    if (_dockProxy == nil) {
        NSConnection *conn = [NSConnection connectionWithRegisteredName:@"DockIcon" host:nil];
        _dockProxy = [conn rootProxy];
    }

    _isRunning = YES;
    _isFinished = NO;
    _wasSuccessful = NO;
    [_startTime release];
    _startTime = [[NSDate date] retain];
    [_lineBuffer setString:@""];
    _currentPercent = 0.0;
    [_detailLabel setStringValue:NSLocalizedString(@"Preparing installation...", @"")];
    [_progressBar setDoubleValue:0.0];
    [_etaLabel setStringValue:@""];
    if ([self logWindowController]) {
        [[self logWindowController] clearLog];
    }

    /* Start ETA update timer */
    [_etaTimer invalidate];
    [_etaTimer release];
    _etaTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                 target:self
                                               selector:@selector(_updateETA:)
                                               userInfo:nil
                                                repeats:YES] retain];

    NSString *scriptPath = IAInstallerScriptPath();
    NSDebugLLog(@"gwcomp", @"IAInstallProgressStep: launching installer %@", scriptPath);

    NSMutableArray *taskArgs = [NSMutableArray array];
    /* If not running as root, use sudo -n (non-interactive) to avoid
       /dev/tty prompts that would block when stdin is a pipe from NSTask */
    NSString *launchBinary = nil;
    if (getuid() != 0) {
        launchBinary = @"/usr/bin/env";
        [taskArgs addObject:@"sudo"];
        [taskArgs addObject:@"-n"];
        [taskArgs addObject:scriptPath];
        NSDebugLLog(@"gwcomp", @"IAInstallProgressStep: not root (uid=%u), wrapping in sudo", getuid());
    } else {
        launchBinary = scriptPath;
        NSDebugLLog(@"gwcomp", @"IAInstallProgressStep: running as root");
    }

    [taskArgs addObjectsFromArray:@[@"--noninteractive", @"--disk", disk.devicePath, @"--debug"]];

    if (sourcePathOrNil && [sourcePathOrNil length] > 0) {
        [taskArgs addObject:@"--source"];
        [taskArgs addObject:sourcePathOrNil];
        NSDebugLLog(@"gwcomp", @"IAInstallProgressStep: using image source %@", sourcePathOrNil);
    }

    [self _appendLog:[NSString stringWithFormat:@"--- Installation started ---\n"]];
    [self _appendLog:[NSString stringWithFormat:@"Script: %@\n", scriptPath]];
    [self _appendLog:[NSString stringWithFormat:@"Target: %@\n\n", disk.devicePath]];

    _installerTask = [[NSTask alloc] init];
    [_installerTask setLaunchPath:launchBinary];
    [_installerTask setArguments:taskArgs];

    [_outputPipe release];
    _outputPipe = [[NSPipe pipe] retain];
    [_installerTask setStandardOutput:_outputPipe];
    [_installerTask setStandardError:_outputPipe]; /* merge stderr into stdout for logging */

    NSFileHandle *readHandle = [_outputPipe fileHandleForReading];

    /* Register for async read notifications (arrives on current run loop) */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_gotOutputData:)
                                                 name:NSFileHandleReadCompletionNotification
                                               object:readHandle];

    /* Register for task termination */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_taskDidTerminate:)
                                                 name:NSTaskDidTerminateNotification
                                               object:_installerTask];

    @try {
        [_installerTask launch];
        NSDebugLLog(@"gwcomp", @"IAInstallProgressStep: task launched (PID %d)",
              [_installerTask processIdentifier]);
    } @catch (NSException *ex) {
        NSDebugLLog(@"gwcomp", @"IAInstallProgressStep: launch failed: %@", ex);
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSFileHandleReadCompletionNotification
                                                      object:readHandle];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSTaskDidTerminateNotification
                                                      object:_installerTask];
        [_installerTask release]; _installerTask = nil;
        [_outputPipe release]; _outputPipe = nil;
        [self _installLaunchFailed:@{@"error": [ex description]}];
        return;
    }

    /* Begin async reading */
    [readHandle readInBackgroundAndNotify];
}

/* ---- Async output handler ---- */
- (void)_gotOutputData:(NSNotification *)notification
{
    NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];
    if (!data || [data length] == 0) {
        /* EOF - flush remaining buffer */
        if ([_lineBuffer length] > 0) {
            [self _processLine:[NSString stringWithString:_lineBuffer]];
            [_lineBuffer setString:@""];
        }
        return;
    }

    NSString *str = [[[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding] autorelease];
    if (!str) {
        str = [[[NSString alloc] initWithData:data
                                     encoding:NSASCIIStringEncoding] autorelease];
    }
    if (str) {
        [_lineBuffer appendString:str];

        /* Extract and process complete lines */
        NSRange range;
        while ((range = [_lineBuffer rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [_lineBuffer substringToIndex:range.location];
            [_lineBuffer deleteCharactersInRange:
                NSMakeRange(0, range.location + 1)];
            [self _processLine:line];
        }
    }

    /* Continue reading next chunk */
    [[notification object] readInBackgroundAndNotify];
}

/* ---- Process a single output line ---- */
- (void)_processLine:(NSString *)line
{
    if ([line length] == 0) return;

    /* Append to log view */
    [self _appendLog:[line stringByAppendingString:@"\n"]];

    /* Parse PROGRESS: lines - format: PROGRESS:phase:percent:message */
    if ([line hasPrefix:@"PROGRESS:"]) {
        NSArray *parts = [line componentsSeparatedByString:@":"];
        if ([parts count] >= 4) {
            NSString *percentStr = parts[2];
            NSString *message = [[parts subarrayWithRange:
                NSMakeRange(3, [parts count] - 3)]
                componentsJoinedByString:@":"];
            double pct = [percentStr doubleValue];

            /* Strip trailing percentage from display message
               e.g., "Copying files... 45%" -> "Copying files..." */
            NSString *displayMsg = message ?: @"";
            NSRange pctSuffix = [displayMsg rangeOfString:@"%"
                                                 options:NSBackwardsSearch];
            if (pctSuffix.location != NSNotFound &&
                pctSuffix.location == [displayMsg length] - 1) {
                NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
                NSUInteger idx = pctSuffix.location;
                while (idx > 0 &&
                       [digits characterIsMember:[displayMsg characterAtIndex:idx - 1]]) {
                    idx--;
                }
                if (idx < pctSuffix.location) {
                    displayMsg = [[displayMsg substringToIndex:idx]
                        stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
                }
            }

            [_detailLabel setStringValue:displayMsg];
            [_progressBar setDoubleValue:pct];
            [((id<DockService>)_dockProxy) setProgressValue:pct / 100.0];
            [((id<DockService>)_dockProxy) setProgressVisible:YES];
            _currentPercent = pct;
            [self _updateETA:nil];
        }
    }
}

/* ---- Append text to log window ---- */
- (void)_appendLog:(NSString *)text
{
    if (!text) return;
    IALogWindowController *logWC = [self logWindowController];
    if (logWC) {
        [logWC appendLog:text];
    }
}

/* ---- Task terminated ---- */
- (void)_taskDidTerminate:(NSNotification *)notification
{
    NSTask *task = [notification object];
    int status = [task terminationStatus];
    NSDebugLLog(@"gwcomp", @"IAInstallProgressStep: task terminated with status %d", status);

    [_etaTimer invalidate];
    [_etaTimer release];
    _etaTimer = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSFileHandleReadCompletionNotification
                                                  object:[_outputPipe fileHandleForReading]];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:_installerTask];

    _isRunning = NO;
    _isFinished = YES;
    _wasSuccessful = (status == 0);

    if (_wasSuccessful) {
        [((id<DockService>)_dockProxy) setProgressValue:1.0];
        [self _appendLog:@"\n--- Installation completed successfully ---\n"];
    } else {
        [((id<DockService>)_dockProxy) setProgressVisible:NO];
        [self _appendLog:[NSString stringWithFormat:
            @"\n--- Installation FAILED (exit code %d) ---\n", status]];
        [_detailLabel setStringValue:
            NSLocalizedString(@"Installation failed. See log for details.", @"")];
    }

    /* Clear ETA on completion */
    [_etaLabel setStringValue:@""];

    /* Notify delegate */
    if (delegate && [delegate respondsToSelector:@selector(installProgressDidFinish:)]) {
        [delegate installProgressDidFinish:_wasSuccessful];
    }
}

/* Main-thread callback: installer script failed to launch */
- (void)_installLaunchFailed:(NSDictionary *)info
{
    (void)info;
    _isRunning = NO;
    _isFinished = YES;
    _wasSuccessful = NO;
    [((id<DockService>)_dockProxy) setProgressVisible:NO];
    [_etaTimer invalidate];
    [_etaTimer release];
    _etaTimer = nil;
    [_detailLabel setStringValue:NSLocalizedString(@"Failed to launch installer script", @"")];
    [_etaLabel setStringValue:@""];
    [self _appendLog:[NSString stringWithFormat:@"LAUNCH ERROR: %@\n",
                      [info objectForKey:@"error"]]];
    if (delegate && [delegate respondsToSelector:@selector(installProgressDidFinish:)]) {
        [delegate installProgressDidFinish:NO];
    }
}

/* ---- ETA update timer ---- */
- (void)_updateETA:(NSTimer *)timer
{
    (void)timer;
    if (!_startTime) return;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:_startTime];

    if (_currentPercent >= 100.0) {
        [_etaLabel setStringValue:@""];
        return;
    }

    if (_currentPercent < 2.0 || elapsed < 10.0) {
        [_etaLabel setStringValue:
            NSLocalizedString(@"Estimating time remaining...", @"")];
        return;
    }

    double rate = _currentPercent / elapsed;
    if (rate < 0.001) {
        [_etaLabel setStringValue:
            NSLocalizedString(@"Estimating time remaining...", @"")];
        return;
    }
    double remaining = (100.0 - _currentPercent) / rate;
    int secs = (int)remaining;

    if (secs > 7200) {
        int hours = secs / 3600;
        int mins = (secs % 3600) / 60;
        [_etaLabel setStringValue:[NSString stringWithFormat:
            NSLocalizedString(@"About %d hours and %d minutes remaining", @""),
            hours, mins]];
    } else if (secs > 120) {
        int mins = (secs + 30) / 60;
        [_etaLabel setStringValue:[NSString stringWithFormat:
            NSLocalizedString(@"About %d minutes remaining", @""), mins]];
    } else if (secs > 60) {
        [_etaLabel setStringValue:
            NSLocalizedString(@"About a minute remaining", @"")];
    } else {
        [_etaLabel setStringValue:
            NSLocalizedString(@"Less than a minute remaining", @"")];
    }
}

- (NSView *)stepView { return _stepView; }
- (NSString *)stepTitle { return stepTitle; }
- (NSString *)stepDescription { return stepDescription; }
- (BOOL)isFinished { return _isFinished; }
- (BOOL)wasSuccessful { return _wasSuccessful; }
- (BOOL)canContinue { return _isFinished; }
- (BOOL)canGoBack { return NO; }

@end
