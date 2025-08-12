//
// InstallationSteps.m
// Installation Assistant - Custom Step Classes
//

#import "InstallationSteps.h"

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
