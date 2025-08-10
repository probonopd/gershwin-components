#import "GSInstallerAssistant.h"

// Helper function to create colored box views since layers aren't available
NSView *createColoredBox(NSRect frame, NSColor *color) {
    NSView *box = [[NSView alloc] initWithFrame:frame];
    // For GNUstep, we'll override drawRect to draw colored backgrounds
    return [box autorelease];
}

@interface GSColoredView : NSView
@property (nonatomic, strong) NSColor *backgroundColor;
@end

@implementation GSColoredView
- (void)drawRect:(NSRect)rect {
    if (_backgroundColor) {
        [_backgroundColor setFill];
        NSRectFill(rect);
    }
    [super drawRect:rect];
}
@end

@implementation GSModernInstallerWindow

- (instancetype)initWithTitle:(NSString *)title 
                         icon:(NSImage *)icon
                        steps:(NSArray<id<GSAssistantStepProtocol>> *)steps {
    
    NSLog(@"[GSModernInstallerWindow] Initializing installer assistant with title: '%@'", title);
    
    // Create fixed-size window matching installer design
    NSRect windowFrame = NSMakeRect(0, 0, GSInstallerWindowWidth, GSInstallerWindowHeight);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:windowFrame
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    
    self = [super initWithWindow:window];
    if (self) {
        _installerTitle = [title copy];
        _installerIcon = [icon retain];
        _steps = [[NSMutableArray alloc] initWithArray:steps];
        _currentStepIndex = 0;
        _stepIndicatorViews = [[NSMutableArray alloc] init];
        
        [self setupWindow];
        [self createMainLayout];
        [self setupSidebar];
        [self setupButtonArea];
        
        if (_steps.count > 0) {
            [self goToStep:0];
        }
    }
    
    return self;
}

- (void)dealloc {
    NSLog(@"[GSInstallerAssistantWindow] Deallocating installer assistant");
    [_installerTitle release];
    [_installerIcon release];
    [_steps release];
    [_stepIndicatorViews release];
    [_mainContainerView release];
    [_sidebarView release];
    [_contentAreaView release];
    [_buttonAreaView release];
    [_backgroundLogoView release];
    [_stepTitleField release];
    [_currentStepContentView release];
    [_optionsButton release];
    [_goBackButton release];
    [_continueButton release];
    [super dealloc];
}

- (void)setupWindow {
    NSWindow *window = [self window];
    [window setTitle:_installerTitle ?: @"Installer"];
    [window setMinSize:NSMakeSize(GSInstallerWindowWidth, GSInstallerWindowHeight)];
    [window setMaxSize:NSMakeSize(GSInstallerWindowWidth, GSInstallerWindowHeight)];
    [window setResizable:NO];
    [window center];
    
    NSLog(@"[GSInstallerAssistantWindow] Window setup complete, size: %.0fx%.0f", 
          GSInstallerWindowWidth, GSInstallerWindowHeight);
}

- (void)createMainLayout {
    NSWindow *window = [self window];
    NSView *windowContentView = [window contentView];
    
    // Main container view
    _mainContainerView = [[NSView alloc] initWithFrame:[windowContentView bounds]];
    [_mainContainerView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [windowContentView addSubview:_mainContainerView];
    
    // Calculate layout dimensions
    CGFloat contentHeight = GSInstallerWindowHeight - GSInstallerButtonAreaHeight;
    CGFloat contentWidth = GSInstallerWindowWidth - GSInstallerSidebarWidth;
    
    // Sidebar view
    NSRect sidebarFrame = NSMakeRect(0, GSInstallerButtonAreaHeight, 
                                   GSInstallerSidebarWidth, contentHeight);
    _sidebarView = [[NSView alloc] initWithFrame:sidebarFrame];
    [_sidebarView setAutoresizingMask:NSViewHeightSizable];
    [_mainContainerView addSubview:_sidebarView];
    
    // Content area view
    NSRect contentFrame = NSMakeRect(GSInstallerSidebarWidth, GSInstallerButtonAreaHeight,
                                   contentWidth, contentHeight);
    _contentAreaView = [[NSView alloc] initWithFrame:contentFrame];
    [_contentAreaView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_mainContainerView addSubview:_contentAreaView];
    
    // Button area view
    NSRect buttonFrame = NSMakeRect(0, 0, GSInstallerWindowWidth, GSInstallerButtonAreaHeight);
    _buttonAreaView = [[NSView alloc] initWithFrame:buttonFrame];
    [_buttonAreaView setAutoresizingMask:NSViewWidthSizable];
    [_mainContainerView addSubview:_buttonAreaView];
    
    NSLog(@"[GSInstallerAssistantWindow] Main layout created - Sidebar: %.0fx%.0f, Content: %.0fx%.0f", 
          GSInstallerSidebarWidth, contentHeight, contentWidth, contentHeight);
}

- (void)setupSidebar {
    // Create background logo (translucent installer icon)
    if (_installerIcon) {
        NSRect logoFrame = NSMakeRect(25, 100, 120, 120);
        _backgroundLogoView = [[NSImageView alloc] initWithFrame:logoFrame];
        [_backgroundLogoView setImage:_installerIcon];
        [_backgroundLogoView setImageAlignment:NSImageAlignCenter];
        [_backgroundLogoView setImageScaling:NSImageScaleProportionallyUpOrDown];
        [_backgroundLogoView setAlphaValue:0.1]; // Very subtle
        [_sidebarView addSubview:_backgroundLogoView];
    }
    
    // Create step indicators
    [self createStepIndicators];
    
    // Add separator line (as a thin colored view)
    NSRect separatorFrame = NSMakeRect(GSInstallerSidebarWidth - 1, 0, 1, 
                                     GSInstallerWindowHeight - GSInstallerButtonAreaHeight);
    GSColoredView *separatorView = [[GSColoredView alloc] initWithFrame:separatorFrame];
    [separatorView setBackgroundColor:[NSColor colorWithCalibratedRed:0.816 green:0.816 blue:0.816 alpha:1.0]];
    [_sidebarView addSubview:separatorView];
    [separatorView release];
    
    NSLog(@"[GSModernInstallerWindow] Sidebar setup complete with %lu step indicators", 
          (unsigned long)_stepIndicatorViews.count);
}

- (void)createStepIndicators {
    CGFloat startY = [_sidebarView frame].size.height - 50; // Start from top with margin
    CGFloat stepHeight = 26; // 24px height + 2px spacing
    
    for (NSInteger i = 0; i < _steps.count; i++) {
        id<GSAssistantStepProtocol> step = _steps[i];
        CGFloat yPosition = startY - (i * stepHeight);
        
        // Create step container view
        NSRect stepFrame = NSMakeRect(10, yPosition, GSInstallerSidebarWidth - 20, 24);
        NSView *stepView = [[NSView alloc] initWithFrame:stepFrame];
        
        // Create circle indicator
        NSRect circleFrame = NSMakeRect(0, 2, 20, 20);
        NSView *circleView = [[NSView alloc] initWithFrame:circleFrame];
        [circleView setWantsLayer:YES];
        circleView.layer.cornerRadius = 10;
        
        // Create step label
        NSRect labelFrame = NSMakeRect(30, 0, stepFrame.size.width - 35, 24);
        NSTextField *stepLabel = [[NSTextField alloc] initWithFrame:labelFrame];
        [stepLabel setStringValue:[step stepTitle]];
        [stepLabel setBezeled:NO];
        [stepLabel setDrawsBackground:NO];
        [stepLabel setEditable:NO];
        [stepLabel setSelectable:NO];
        [stepLabel setFont:[NSFont systemFontOfSize:13]];
        
        [stepView addSubview:circleView];
        [stepView addSubview:stepLabel];
        [_sidebarView addSubview:stepView];
        [_stepIndicatorViews addObject:stepView];
        
        [circleView release];
        [stepLabel release];
        [stepView release];
    }
}

- (void)updateStepIndicators {
    for (NSInteger i = 0; i < _stepIndicatorViews.count; i++) {
        NSView *stepView = _stepIndicatorViews[i];
        NSView *circleView = [[stepView subviews] objectAtIndex:0];
        NSTextField *labelField = [[stepView subviews] objectAtIndex:1];
        
        if (i < _currentStepIndex) {
            // Completed step - blue circle with checkmark
            circleView.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.0 green:0.478 blue:1.0 alpha:1.0] CGColor];
            [labelField setTextColor:[NSColor blackColor]];
        } else if (i == _currentStepIndex) {
            // Current step - blue circle
            circleView.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.0 green:0.478 blue:1.0 alpha:1.0] CGColor];
            [labelField setTextColor:[NSColor blackColor]];
            [labelField setFont:[NSFont boldSystemFontOfSize:13]];
        } else {
            // Future step - gray outline
            circleView.layer.backgroundColor = [[NSColor clearColor] CGColor];
            circleView.layer.borderWidth = 1.0;
            circleView.layer.borderColor = [[NSColor colorWithCalibratedRed:0.4 green:0.4 blue:0.4 alpha:1.0] CGColor];
            [labelField setTextColor:[NSColor colorWithCalibratedRed:0.4 green:0.4 blue:0.4 alpha:1.0]];
            [labelField setFont:[NSFont systemFontOfSize:13]];
        }
    }
}

- (void)setupButtonArea {
    // Set button area background
    [_buttonAreaView setWantsLayer:YES];
    _buttonAreaView.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.941 green:0.949 blue:0.961 alpha:1.0] CGColor];
    
    // Add top separator line
    NSRect separatorFrame = NSMakeRect(0, GSInstallerButtonAreaHeight - 1, GSInstallerWindowWidth, 1);
    NSView *separatorView = [[NSView alloc] initWithFrame:separatorFrame];
    [separatorView setWantsLayer:YES];
    separatorView.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.816 green:0.816 blue:0.816 alpha:1.0] CGColor];
    [_buttonAreaView addSubview:separatorView];
    [separatorView release];
    
    // Create buttons with standard spacing - 20px from bottom edge, 24px height
    CGFloat buttonY = 20; // 20px from bottom edge as per spacing guidelines
    
    // Options button (left side, only shown when applicable) with standard margin
    NSRect optionsFrame = NSMakeRect(24, buttonY, GSInstallerButtonWidth, 24);
    _optionsButton = [[NSButton alloc] initWithFrame:optionsFrame];
    [_optionsButton setTitle:@"Options..."];
    [_optionsButton setBezelStyle:NSRoundedBezelStyle];
    [_optionsButton setTarget:self];
    [_optionsButton setAction:@selector(optionsButtonClicked:)];
    [_optionsButton setHidden:YES]; // Hidden by default
    [_buttonAreaView addSubview:_optionsButton];
    
    // Continue button (right side) with standard margins and spacing
    NSRect continueFrame = NSMakeRect(GSInstallerWindowWidth - 24 - 100, buttonY, 100, 24);
    _continueButton = [[NSButton alloc] initWithFrame:continueFrame];
    [_continueButton setTitle:@"Continue"];
    [_continueButton setBezelStyle:NSRoundedBezelStyle];
    [_continueButton setKeyEquivalent:@"\r"];
    [_continueButton setTarget:self];
    [_continueButton setAction:@selector(continueButtonClicked:)];
    [_buttonAreaView addSubview:_continueButton];
    
    // Go Back button (left of continue button) with standard 12px spacing
    NSRect backFrame = NSMakeRect(GSInstallerWindowWidth - 24 - 100 - 12 - GSInstallerButtonWidth, 
                                buttonY, GSInstallerButtonWidth, 24);
    _goBackButton = [[NSButton alloc] initWithFrame:backFrame];
    [_goBackButton setTitle:@"Go Back"];
    [_goBackButton setBezelStyle:NSRoundedBezelStyle];
    [_goBackButton setTarget:self];
    [_goBackButton setAction:@selector(goBackButtonClicked:)];
    [_goBackButton setEnabled:NO]; // Disabled initially
    [_buttonAreaView addSubview:_goBackButton];
    
    NSLog(@"[GSInstallerAssistantWindow] Button area setup complete");
}

- (void)setupContentArea {
    // Clear existing content
    for (NSView *subview in [_contentAreaView subviews]) {
        [subview removeFromSuperview];
    }
    
    // Set content area background to white
    [_contentAreaView setWantsLayer:YES];
    _contentAreaView.layer.backgroundColor = [[NSColor whiteColor] CGColor];
    
    if (_currentStepIndex < _steps.count) {
        id<GSAssistantStepProtocol> currentStep = _steps[_currentStepIndex];
        
        // Create step title
        NSRect titleFrame = NSMakeRect(40, [_contentAreaView frame].size.height - 80, 
                                     [_contentAreaView frame].size.width - 80, 30);
        _stepTitleField = [[NSTextField alloc] initWithFrame:titleFrame];
        [_stepTitleField setStringValue:[currentStep stepTitle]];
        [_stepTitleField setBezeled:NO];
        [_stepTitleField setDrawsBackground:NO];
        [_stepTitleField setEditable:NO];
        [_stepTitleField setSelectable:NO];
        [_stepTitleField setFont:[NSFont boldSystemFontOfSize:20]];
        [_stepTitleField setTextColor:[NSColor blackColor]];
        [_contentAreaView addSubview:_stepTitleField];
        
        // Add step content view
        NSView *stepContentView = [currentStep stepView];
        if (stepContentView) {
            NSRect contentFrame = NSMakeRect(40, 40, 
                                           [_contentAreaView frame].size.width - 80,
                                           [_contentAreaView frame].size.height - 120);
            [stepContentView setFrame:contentFrame];
            [_contentAreaView addSubview:stepContentView];
            _currentStepContentView = stepContentView;
        }
    }
}

- (void)goToStep:(NSInteger)stepIndex {
    if (stepIndex < 0 || stepIndex >= _steps.count) {
        NSLog(@"[GSInstallerAssistantWindow] Invalid step index: %ld", (long)stepIndex);
        return;
    }
    
    NSLog(@"[GSInstallerAssistantWindow] Going to step %ld", (long)stepIndex);
    
    _currentStepIndex = stepIndex;
    [self setupContentArea];
    [self updateStepIndicators];
    [self updateNavigationButtons];
}

- (void)updateNavigationButtons {
    // Update Go Back button
    [_goBackButton setEnabled:(_currentStepIndex > 0)];
    
    // Update Continue button
    id<GSAssistantStepProtocol> currentStep = _steps[_currentStepIndex];
    BOOL canContinue = [currentStep canContinue];
    [_continueButton setEnabled:canContinue];
    
    // Update button text based on step
    if (_currentStepIndex == _steps.count - 1) {
        [_continueButton setTitle:@"Restart"];
    } else {
        [_continueButton setTitle:@"Continue"];
    }
    
    // Show/hide Options button based on step type
    [_optionsButton setHidden:YES]; // Hide by default, show for specific steps
}

- (void)nextStep {
    if (_currentStepIndex < _steps.count - 1) {
        [self goToStep:_currentStepIndex + 1];
    }
}

- (void)previousStep {
    if (_currentStepIndex > 0) {
        [self goToStep:_currentStepIndex - 1];
    }
}

#pragma mark - Button Actions

- (void)optionsButtonClicked:(id)sender {
    NSLog(@"[GSInstallerAssistantWindow] Options button clicked");
    // Handle options - to be implemented based on specific step needs
}

- (void)goBackButtonClicked:(id)sender {
    NSLog(@"[GSInstallerAssistantWindow] Go Back button clicked");
    [self previousStep];
}

- (void)continueButtonClicked:(id)sender {
    NSLog(@"[GSInstallerAssistantWindow] Continue button clicked");
    
    if (_currentStepIndex == _steps.count - 1) {
        // Last step - handle completion
        NSLog(@"[GSInstallerAssistantWindow] Installation complete, initiating restart");
        // Handle restart or completion
    } else {
        [self nextStep];
    }
}

@end

#pragma mark - GSInstallerStep Implementation

@implementation GSInstallerStep

- (instancetype)initWithTitle:(NSString *)title description:(NSString *)description {
    self = [super init];
    if (self) {
        _title = [title copy];
        _stepDescription = [description copy];
        _canProceed = YES;
        _contentView = [[self createContentView] retain];
    }
    return self;
}

- (void)dealloc {
    [_title release];
    [_stepDescription release];
    [_contentView release];
    [super dealloc];
}

- (NSString *)stepTitle {
    return _title;
}

- (NSString *)stepDescription {
    return _stepDescription;
}

- (NSView *)stepView {
    return _contentView;
}

- (BOOL)canContinue {
    return _canProceed;
}

- (NSView *)createContentView {
    // Default implementation - override in subclasses
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    return [view autorelease];
}

@end

#pragma mark - GSIntroductionStep Implementation

@implementation GSIntroductionStep

- (instancetype)initWithWelcomeMessage:(NSString *)message icons:(NSArray<NSImage *> *)icons {
    self = [super initWithTitle:@"Welcome to the Installer" description:message];
    if (self) {
        _welcomeMessage = [message copy];
        _applicationIcons = [icons copy];
    }
    return self;
}

- (void)dealloc {
    [_welcomeMessage release];
    [_applicationIcons release];
    [super dealloc];
}

- (NSView *)createContentView {
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    
    // Welcome message
    NSRect messageFrame = NSMakeRect(0, 200, 400, 60);
    NSTextField *messageField = [[NSTextField alloc] initWithFrame:messageFrame];
    [messageField setStringValue:_welcomeMessage ?: @"To install, click Continue then follow the onscreen instructions."];
    [messageField setBezeled:NO];
    [messageField setDrawsBackground:NO];
    [messageField setEditable:NO];
    [messageField setSelectable:NO];
    [messageField setFont:[NSFont systemFontOfSize:13]];
    [messageField setTextColor:[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:1.0]];
    [contentView addSubview:messageField];
    [messageField release];
    
    // Application icons array
    if (_applicationIcons.count > 0) {
        CGFloat iconSize = 48;
        CGFloat spacing = 16;
        CGFloat totalWidth = (_applicationIcons.count * iconSize) + ((_applicationIcons.count - 1) * spacing);
        CGFloat startX = (400 - totalWidth) / 2;
        
        for (NSInteger i = 0; i < _applicationIcons.count; i++) {
            NSImage *icon = _applicationIcons[i];
            CGFloat x = startX + (i * (iconSize + spacing));
            NSRect iconFrame = NSMakeRect(x, 120, iconSize, iconSize);
            
            NSImageView *iconView = [[NSImageView alloc] initWithFrame:iconFrame];
            [iconView setImage:icon];
            [iconView setImageAlignment:NSImageAlignCenter];
            [iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
            [contentView addSubview:iconView];
            [iconView release];
        }
    }
    
    return [contentView autorelease];
}

@end

#pragma mark - GSDestinationStep Implementation

@implementation GSDestinationStep

- (NSView *)createContentView {
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    
    // Description text
    NSRect descFrame = NSMakeRect(0, 240, 400, 40);
    NSTextField *descField = [[NSTextField alloc] initWithFrame:descFrame];
    [descField setStringValue:@"Select a destination volume to install the software."];
    [descField setBezeled:NO];
    [descField setDrawsBackground:NO];
    [descField setEditable:NO];
    [descField setSelectable:NO];
    [descField setFont:[NSFont systemFontOfSize:13]];
    [descField setTextColor:[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:1.0]];
    [contentView addSubview:descField];
    [descField release];
    
    // Disk selection area
    NSRect diskFrame = NSMakeRect(50, 140, 300, 80);
    NSView *diskView = [[NSView alloc] initWithFrame:diskFrame];
    [diskView setWantsLayer:YES];
    diskView.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.95 green:0.95 blue:0.95 alpha:1.0] CGColor];
    diskView.layer.cornerRadius = 8;
    
    // Disk icon (placeholder)
    NSRect diskIconFrame = NSMakeRect(20, 16, 48, 48);
    NSImageView *diskIconView = [[NSImageView alloc] initWithFrame:diskIconFrame];
    // Set a generic disk icon here
    [diskView addSubview:diskIconView];
    [diskIconView release];
    
    // Disk name and info
    NSRect diskNameFrame = NSMakeRect(80, 45, 200, 20);
    NSTextField *diskNameField = [[NSTextField alloc] initWithFrame:diskNameFrame];
    [diskNameField setStringValue:@"Tiger"];
    [diskNameField setBezeled:NO];
    [diskNameField setDrawsBackground:NO];
    [diskNameField setEditable:NO];
    [diskNameField setSelectable:NO];
    [diskNameField setFont:[NSFont boldSystemFontOfSize:14]];
    [diskView addSubview:diskNameField];
    [diskNameField release];
    
    NSRect diskInfoFrame = NSMakeRect(80, 25, 200, 16);
    NSTextField *diskInfoField = [[NSTextField alloc] initWithFrame:diskInfoFrame];
    [diskInfoField setStringValue:@"126GB (126GB Free)"];
    [diskInfoField setBezeled:NO];
    [diskInfoField setDrawsBackground:NO];
    [diskInfoField setEditable:NO];
    [diskInfoField setSelectable:NO];
    [diskInfoField setFont:[NSFont systemFontOfSize:11]];
    [diskInfoField setTextColor:[NSColor grayColor]];
    [diskView addSubview:diskInfoField];
    [diskInfoField release];
    
    [contentView addSubview:diskView];
    [diskView release];
    
    // Space requirements
    NSRect reqFrame = NSMakeRect(0, 80, 400, 40);
    NSTextField *reqField = [[NSTextField alloc] initWithFrame:reqFrame];
    [reqField setStringValue:@"Installing this software requires 4.7GB of space.\n\nYou have selected to install on this volume."];
    [reqField setBezeled:NO];
    [reqField setDrawsBackground:NO];
    [reqField setEditable:NO];
    [reqField setSelectable:NO];
    [reqField setFont:[NSFont systemFontOfSize:11]];
    [reqField setTextColor:[NSColor grayColor]];
    [contentView addSubview:reqField];
    [reqField release];
    
    return [contentView autorelease];
}

@end

#pragma mark - GSInstallationProgressStep Implementation

@implementation GSInstallationProgressStep

- (NSView *)createContentView {
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    
    // Progress bar
    NSRect progressFrame = NSMakeRect(0, 180, 400, 20);
    _progressBar = [[NSProgressIndicator alloc] initWithFrame:progressFrame];
    [_progressBar setStyle:NSProgressIndicatorBarStyle];
    [_progressBar setIndeterminate:NO];
    [_progressBar setMinValue:0.0];
    [_progressBar setMaxValue:100.0];
    [_progressBar setDoubleValue:68.0]; // Match screenshot
    [contentView addSubview:_progressBar];
    
    // Status label
    NSRect statusFrame = NSMakeRect(0, 150, 400, 20);
    _statusLabel = [[NSTextField alloc] initWithFrame:statusFrame];
    [_statusLabel setStringValue:@"Writing files: 68% Completed"];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setFont:[NSFont systemFontOfSize:13]];
    [contentView addSubview:_statusLabel];
    
    // Time remaining label
    NSRect timeFrame = NSMakeRect(0, 120, 400, 20);
    _timeRemainingLabel = [[NSTextField alloc] initWithFrame:timeFrame];
    [_timeRemainingLabel setStringValue:@"Time Remaining: About a minute"];
    [_timeRemainingLabel setBezeled:NO];
    [_timeRemainingLabel setDrawsBackground:NO];
    [_timeRemainingLabel setEditable:NO];
    [_timeRemainingLabel setSelectable:NO];
    [_timeRemainingLabel setFont:[NSFont systemFontOfSize:13]];
    [contentView addSubview:_timeRemainingLabel];
    
    return [contentView autorelease];
}

- (void)updateProgress:(double)progress status:(NSString *)status timeRemaining:(NSString *)timeString {
    _progressValue = progress;
    [_progressBar setDoubleValue:progress];
    [_statusLabel setStringValue:status];
    [_timeRemainingLabel setStringValue:timeString];
    
    NSLog(@"[GSInstallationProgressStep] Progress updated: %.1f%% - %@", progress, status);
}

- (void)dealloc {
    [_progressBar release];
    [_statusLabel release];
    [_timeRemainingLabel release];
    [super dealloc];
}

@end

#pragma mark - GSCompletionStep Implementation

@implementation GSCompletionStep

- (NSView *)createContentView {
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    
    // Completion message
    NSRect messageFrame = NSMakeRect(0, 200, 400, 60);
    _completionMessageLabel = [[NSTextField alloc] initWithFrame:messageFrame];
    [_completionMessageLabel setStringValue:@"The installation was completed successfully."];
    [_completionMessageLabel setBezeled:NO];
    [_completionMessageLabel setDrawsBackground:NO];
    [_completionMessageLabel setEditable:NO];
    [_completionMessageLabel setSelectable:NO];
    [_completionMessageLabel setFont:[NSFont systemFontOfSize:13]];
    [contentView addSubview:_completionMessageLabel];
    
    // Countdown label
    NSRect countdownFrame = NSMakeRect(0, 140, 400, 40);
    _countdownLabel = [[NSTextField alloc] initWithFrame:countdownFrame];
    [_countdownLabel setStringValue:@"The computer will restart in 29 seconds"];
    [_countdownLabel setBezeled:NO];
    [_countdownLabel setDrawsBackground:NO];
    [_countdownLabel setEditable:NO];
    [_countdownLabel setSelectable:NO];
    [_countdownLabel setFont:[NSFont systemFontOfSize:13]];
    [_countdownLabel setAlignment:NSTextAlignmentCenter];
    [contentView addSubview:_countdownLabel];
    
    return [contentView autorelease];
}

- (void)startRestartCountdown:(NSInteger)seconds {
    _countdownSeconds = seconds;
    [self updateCountdownDisplay];
    
    // Start timer to update countdown
    [NSTimer scheduledTimerWithTimeInterval:1.0
                                     target:self
                                   selector:@selector(updateCountdown:)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)updateCountdown:(NSTimer *)timer {
    _countdownSeconds--;
    [self updateCountdownDisplay];
    
    if (_countdownSeconds <= 0) {
        [timer invalidate];
        // Trigger restart or completion action
    }
}

- (void)updateCountdownDisplay {
    [_countdownLabel setStringValue:[NSString stringWithFormat:@"The computer will restart in %ld seconds", 
                                   (long)_countdownSeconds]];
}

- (void)dealloc {
    [_completionMessageLabel release];
    [_countdownLabel release];
    [super dealloc];
}

@end
