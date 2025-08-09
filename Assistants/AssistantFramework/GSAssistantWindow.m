#import "GSAssistantFramework.h"

// Layout constants implementation
const CGFloat GSAssistantDefaultWindowWidth = 700.0;
const CGFloat GSAssistantDefaultWindowHeight = 500.0;
const CGFloat GSAssistantInstallerWindowWidth = 620.0;
const CGFloat GSAssistantInstallerWindowHeight = 460.0;
const CGFloat GSAssistantInstallerSidebarWidth = 170.0;
const CGFloat GSAssistantInstallerButtonAreaHeight = 60.0;

// Legacy constants for compatibility
static const CGFloat GSAssistantWindowMinWidth = 600.0;
static const CGFloat GSAssistantWindowMinHeight = 450.0;

// Helper view for colored backgrounds (GNUstep compatible)
@interface GSColoredBackgroundView : NSView
@property (nonatomic, strong) NSColor *backgroundColor;
@end

@implementation GSColoredBackgroundView
- (void)drawRect:(NSRect)rect {
    if (_backgroundColor) {
        [_backgroundColor setFill];
        NSRectFill(rect);
    }
    [super drawRect:rect];
}
- (void)dealloc {
    [_backgroundColor release];
    [super dealloc];
}
@end

@interface GSAssistantWindow ()

@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSView *sidebarView;
@property (nonatomic, strong) NSView *mainContentView;
@property (nonatomic, strong) NSView *stepContentView;
@property (nonatomic, strong) NSView *footerView;
@property (nonatomic, strong) NSView *navigationView;

// Sidebar elements
@property (nonatomic, strong) NSImageView *sidebarImageView;
@property (nonatomic, strong) NSMutableArray<NSView *> *stepLabels;

// Main content elements
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *stepTitleLabel;
@property (nonatomic, strong) NSTextField *stepDescriptionLabel;

// Navigation elements
@property (nonatomic, strong) NSButton *backButton;
@property (nonatomic, strong) NSButton *continueButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *optionsButton; // For installer layout

@property (nonatomic, strong) NSMutableArray<id<GSAssistantStepProtocol>> *stepsArray;
@property (nonatomic, assign) NSInteger currentIndex;

// Layout properties
@property (nonatomic, assign) CGFloat windowWidth;
@property (nonatomic, assign) CGFloat windowHeight;

// Installer layout views
@property (nonatomic, strong) NSView *installerButtonAreaView;
@property (nonatomic, strong) NSMutableArray<NSView *> *stepIndicatorViews;

@end

@implementation GSAssistantWindow

#pragma mark - Properties

- (NSMutableArray<id<GSAssistantStepProtocol>> *)steps {
    return _stepsArray;
}

- (NSInteger)currentStepIndex {
    return _currentIndex;
}

#pragma mark - Initialization

- (instancetype)init {
    return [self initWithAssistantTitle:nil icon:nil steps:@[]];
}

- (instancetype)initWithSteps:(NSArray<id<GSAssistantStepProtocol>> *)steps {
    return [self initWithAssistantTitle:nil icon:nil steps:steps];
}

- (instancetype)initWithAssistantTitle:(NSString *)title 
                                  icon:(NSImage *)icon
                                 steps:(NSArray<id<GSAssistantStepProtocol>> *)steps {
    // Use default layout style for backward compatibility
    return [self initWithLayoutStyle:GSAssistantLayoutStyleDefault 
                               title:title 
                                icon:icon 
                               steps:steps];
}

- (instancetype)initWithLayoutStyle:(GSAssistantLayoutStyle)layoutStyle
                               title:(nullable NSString *)title 
                                icon:(nullable NSImage *)icon
                               steps:(NSArray<id<GSAssistantStepProtocol>> *)steps {
    
    NSLog(@"[GSAssistantWindow] Initializing with layout style %ld, title: '%@', steps count: %lu", 
          (long)layoutStyle, title, (unsigned long)steps.count);
    
    // Determine window dimensions based on layout style
    CGFloat windowWidth, windowHeight;
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
    
    switch (layoutStyle) {
        case GSAssistantLayoutStyleInstaller:
            windowWidth = GSAssistantInstallerWindowWidth;
            windowHeight = GSAssistantInstallerWindowHeight;
            // Installer windows are not resizable
            break;
            
        case GSAssistantLayoutStyleDefault:
        default:
            windowWidth = GSAssistantDefaultWindowWidth;
            windowHeight = GSAssistantDefaultWindowHeight;
            styleMask |= NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
            break;
    }
    
    NSRect windowFrame = NSMakeRect(0, 0, windowWidth, windowHeight);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:windowFrame
                                                   styleMask:styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    
    self = [super initWithWindow:window];
    if (self) {
        _layoutStyle = layoutStyle;
        _windowWidth = windowWidth;
        _windowHeight = windowHeight;
        _assistantTitle = [title copy];
        _assistantIcon = [icon retain];
        _stepsArray = [[NSMutableArray alloc] initWithArray:steps];
        _currentIndex = 0;
        _showsProgressBar = (layoutStyle == GSAssistantLayoutStyleDefault);
        _allowsCancel = YES;
        _showsSidebar = (layoutStyle == GSAssistantLayoutStyleInstaller);
        _showsStepIndicators = (layoutStyle == GSAssistantLayoutStyleInstaller);
        _stepIndicatorViews = [[NSMutableArray alloc] init];
        
        [self setupWindow];
        [self setupViews];
        if (_stepsArray.count > 0) {
            [self showCurrentStep];
        }
    }
    
    [window release];
    return self;
}

- (void)dealloc {
    [_stepsArray release];
    [_contentView release];
    [_sidebarView release];
    [_mainContentView release];
    [_stepContentView release];
    [_footerView release];
    [_navigationView release];
    [_sidebarImageView release];
    [_stepLabels release];
    [_titleLabel release];
    [_stepTitleLabel release];
    [_stepDescriptionLabel release];
    [_backButton release];
    [_continueButton release];
    [_cancelButton release];
    [_optionsButton release];
    [_installerButtonAreaView release];
    [_stepIndicatorViews release];
    [_assistantTitle release];
    [_assistantIcon release];
    [super dealloc];
}

#pragma mark - Window Setup

- (void)setupWindow {
    NSWindow *window = self.window;
    window.title = _assistantTitle ?: @"Setup Assistant";
    
    // Set window size constraints based on layout style
    if (_layoutStyle == GSAssistantLayoutStyleInstaller) {
        window.minSize = NSMakeSize(_windowWidth, _windowHeight);
        window.maxSize = NSMakeSize(_windowWidth, _windowHeight);
    } else {
        window.minSize = NSMakeSize(GSAssistantWindowMinWidth, GSAssistantWindowMinHeight);
    }
    
    [window center];
    
    _contentView = [[NSView alloc] init];
    window.contentView = _contentView;
    
    NSLog(@"[GSAssistantWindow] Window setup complete with layout style %ld, size: %.0fx%.0f", 
          (long)_layoutStyle, _windowWidth, _windowHeight);
}

- (void)setupViews {
    if (_layoutStyle == GSAssistantLayoutStyleInstaller) {
        [self setupInstallerLayout];
    } else {
        [self setupDefaultLayout];
    }
}

- (void)setupDefaultLayout {
    [self setupSidebarView];
    [self setupMainContentView];
    [self setupFooterView];
}

- (void)setupInstallerLayout {
    [self setupInstallerSidebarView];
    [self setupInstallerContentView];
    [self setupInstallerButtonArea];
}

- (void)setupSidebarView {
    _sidebarView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 180, 500)];
    [_contentView addSubview:_sidebarView];
    
    // Add separator line
    NSView *separator = [[NSView alloc] initWithFrame:NSMakeRect(179, 0, 1, 500)];
    [_contentView addSubview:separator];
    [separator release];
    
    // Background image area
    _sidebarImageView = [[NSImageView alloc] initWithFrame:NSMakeRect(10, 150, 160, 200)];
    _sidebarImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _sidebarImageView.alphaValue = 0.08;
    [_sidebarView addSubview:_sidebarImageView];
    
    // Initialize step labels array
    _stepLabels = [[NSMutableArray alloc] init];
    
    // Create step indicators
    CGFloat currentY = 400;
    for (NSUInteger i = 0; i < _stepsArray.count; i++) {
        id<GSAssistantStepProtocol> step = _stepsArray[i];
        
        NSView *stepContainer = [[NSView alloc] initWithFrame:NSMakeRect(15, currentY, 150, 30)];
        
        // Step number
        NSTextField *stepNumber = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 5, 20, 20)];
        stepNumber.editable = NO;
        stepNumber.selectable = NO;
        stepNumber.bordered = NO;
        stepNumber.drawsBackground = NO;
        stepNumber.backgroundColor = [NSColor clearColor];
        stepNumber.font = [NSFont boldSystemFontOfSize:11.0];
        stepNumber.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)(i+1)];
        stepNumber.textColor = [NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:1.0];
        stepNumber.alignment = NSCenterTextAlignment;
        [stepContainer addSubview:stepNumber];
        [stepNumber release];
        
        // Step title
        NSTextField *stepLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(25, 5, 125, 20)];
        stepLabel.editable = NO;
        stepLabel.selectable = NO;
        stepLabel.bordered = NO;
        stepLabel.drawsBackground = NO;
        stepLabel.backgroundColor = [NSColor clearColor];
        stepLabel.font = [NSFont systemFontOfSize:12.0];
        stepLabel.stringValue = [step stepTitle];
        stepLabel.textColor = [NSColor colorWithCalibratedRed:0.25 green:0.25 blue:0.25 alpha:1.0];
        [stepContainer addSubview:stepLabel];
        [stepLabel release];
        
        [_sidebarView addSubview:stepContainer];
        [_stepLabels addObject:stepContainer];
        [stepContainer release];
        
        currentY -= 35;
    }
}

- (void)setupMainContentView {
    _mainContentView = [[NSView alloc] initWithFrame:NSMakeRect(180, 60, 520, 380)];
    [_contentView addSubview:_mainContentView];
    
    // Main title - moved down further from y=310 to y=280
    _titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 280, 460, 30)];
    _titleLabel.editable = NO;
    _titleLabel.selectable = NO;
    _titleLabel.bordered = NO;
    _titleLabel.bezeled = NO;
    _titleLabel.drawsBackground = NO;
    _titleLabel.backgroundColor = [NSColor clearColor];
    _titleLabel.font = [NSFont boldSystemFontOfSize:20.0];
    _titleLabel.textColor = [NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0];
    _titleLabel.stringValue = _assistantTitle ?: @"Setup Assistant";
    [_mainContentView addSubview:_titleLabel];
    
    // Step title - moved down further from y=275 to y=245
    _stepTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 245, 460, 24)];
    _stepTitleLabel.editable = NO;
    _stepTitleLabel.selectable = NO;
    _stepTitleLabel.bordered = NO;
    _stepTitleLabel.bezeled = NO;
    _stepTitleLabel.drawsBackground = NO;
    _stepTitleLabel.backgroundColor = [NSColor clearColor];
    _stepTitleLabel.font = [NSFont boldSystemFontOfSize:16.0];
    _stepTitleLabel.textColor = [NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.15 alpha:1.0];
    [_mainContentView addSubview:_stepTitleLabel];
    
    // Step description - moved down further from y=250 to y=220
    _stepDescriptionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 220, 460, 20)];
    _stepDescriptionLabel.editable = NO;
    _stepDescriptionLabel.selectable = NO;
    _stepDescriptionLabel.bordered = NO;
    _stepDescriptionLabel.bezeled = NO;
    _stepDescriptionLabel.drawsBackground = NO;
    _stepDescriptionLabel.backgroundColor = [NSColor clearColor];
    _stepDescriptionLabel.font = [NSFont systemFontOfSize:13.0];
    _stepDescriptionLabel.textColor = [NSColor colorWithCalibratedRed:0.4 green:0.4 blue:0.4 alpha:1.0];
    [_mainContentView addSubview:_stepDescriptionLabel];
    
    // Step content area - increased height and moved down further: y=30 to y=20, height 210 to 190
    _stepContentView = [[NSView alloc] initWithFrame:NSMakeRect(30, 20, 460, 190)];
    [_mainContentView addSubview:_stepContentView];
}

- (void)setupFooterView {
    _footerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 60)];
    [_contentView addSubview:_footerView];
    
    // Top border
    NSView *topBorder = [[NSView alloc] initWithFrame:NSMakeRect(0, 59, 700, 1)];
    [_footerView addSubview:topBorder];
    [topBorder release];
    
    [self setupNavigationView];
}

- (void)setupNavigationView {
    _navigationView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 60)];
    [_footerView addSubview:_navigationView];
    
    // Cancel button
    _cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 14, 85, 32)];
    _cancelButton.title = @"Cancel";
    _cancelButton.bezelStyle = NSRoundedBezelStyle;
    _cancelButton.font = [NSFont systemFontOfSize:13.0];
    _cancelButton.target = self;
    _cancelButton.action = @selector(cancelButtonClicked:);
    [_navigationView addSubview:_cancelButton];
    
    // Back button
    _backButton = [[NSButton alloc] initWithFrame:NSMakeRect(500, 14, 85, 32)];
    _backButton.title = @"Go Back";
    _backButton.bezelStyle = NSRoundedBezelStyle;
    _backButton.font = [NSFont systemFontOfSize:13.0];
    _backButton.target = self;
    _backButton.action = @selector(backButtonClicked:);
    [_navigationView addSubview:_backButton];
    
    // Continue button
    _continueButton = [[NSButton alloc] initWithFrame:NSMakeRect(595, 14, 85, 32)];
    _continueButton.title = @"Continue";
    _continueButton.bezelStyle = NSRoundedBezelStyle;
    _continueButton.font = [NSFont systemFontOfSize:13.0];
    _continueButton.keyEquivalent = @"\r";
    _continueButton.target = self;
    _continueButton.action = @selector(continueButtonClicked:);
    _continueButton.enabled = NO; // Disabled by default until step allows it
    [_navigationView addSubview:_continueButton];
}

#pragma mark - Button Actions

- (void)cancelButtonClicked:(id)sender {
    NSLog(@"[GSAssistantWindow] Cancel button clicked from default layout");
    [self cancelAssistant];
}

- (void)backButtonClicked:(id)sender {
    NSLog(@"[GSAssistantWindow] Back button clicked from default layout");
    [self goToPreviousStep];
}

- (void)continueButtonClicked:(id)sender {
    NSLog(@"[GSAssistantWindow] Continue button clicked from default layout");
    [self goToNextStep];
}

#pragma mark - Step Management

- (void)addStep:(id<GSAssistantStepProtocol>)step {
    [_stepsArray addObject:step];
}

- (void)insertStep:(id<GSAssistantStepProtocol>)step atIndex:(NSInteger)index {
    [_stepsArray insertObject:step atIndex:index];
}

- (void)removeStepAtIndex:(NSInteger)index {
    if (index >= 0 && (NSUInteger)index < _stepsArray.count) {
        [_stepsArray removeObjectAtIndex:index];
        if ((NSUInteger)_currentIndex >= _stepsArray.count) {
            _currentIndex = _stepsArray.count - 1;
        }
    }
}

- (void)removeStep:(id<GSAssistantStepProtocol>)step {
    NSInteger index = [_stepsArray indexOfObject:step];
    if (index != NSNotFound) {
        [self removeStepAtIndex:index];
    }
}

- (id<GSAssistantStepProtocol>)currentStep {
    if (_currentIndex >= 0 && (NSUInteger)_currentIndex < _stepsArray.count) {
        return _stepsArray[_currentIndex];
    }
    return nil;
}

#pragma mark - Navigation

- (void)showCurrentStep {
    id<GSAssistantStepProtocol> step = [self currentStep];
    if (!step) return;
    
    // Notify delegate
    if ([self.delegate respondsToSelector:@selector(assistantWindow:willShowStep:)]) {
        [self.delegate assistantWindow:self willShowStep:step];
    }
    
    // Call step lifecycle methods
    if ([step respondsToSelector:@selector(stepWillAppear)]) {
        [step stepWillAppear];
    }
    
    // Update UI based on layout style
    if (_layoutStyle == GSAssistantLayoutStyleInstaller) {
        [self setupInstallerStepContent];
        [self updateInstallerStepIndicators];
        [self updateInstallerNavigationButtons];
    } else {
        [self updateStepInfo];
        [self showStepView:step];
        [self updateSidebarHighlighting];
        [self updateDefaultNavigationButtons];
    }
    
    // Call step lifecycle methods
    if ([step respondsToSelector:@selector(stepDidAppear)]) {
        [step stepDidAppear];
    }
    
    // Notify delegate
    if ([self.delegate respondsToSelector:@selector(assistantWindow:didShowStep:)]) {
        [self.delegate assistantWindow:self didShowStep:step];
    }
}

- (void)showStepView:(id<GSAssistantStepProtocol>)step {
    // Remove current step view
    for (NSView *subview in _stepContentView.subviews) {
        [subview removeFromSuperview];
    }
    
    // Add new step view
    NSView *stepView = [step stepView];
    if (stepView) {
        NSRect stepFrame = stepView.frame;
        CGFloat centeredX = (460 - stepFrame.size.width) / 2;  // Updated for new content area width
        CGFloat centeredY = (190 - stepFrame.size.height) / 2; // Updated for new content area height
        
        if (centeredX < 0) centeredX = 0;
        if (centeredY < 0) centeredY = 0;
        
        stepView.frame = NSMakeRect(centeredX, centeredY, stepFrame.size.width, stepFrame.size.height);
        [_stepContentView addSubview:stepView];
    }
}

- (void)updateSidebarHighlighting {
    for (NSInteger i = 0; i < (NSInteger)_stepLabels.count; i++) {
        NSView *stepContainer = _stepLabels[i];
        
        NSTextField *numberLabel = nil;
        NSTextField *titleLabel = nil;
        
        for (NSView *subview in stepContainer.subviews) {
            if ([subview isKindOfClass:[NSTextField class]]) {
                NSTextField *textField = (NSTextField *)subview;
                if (textField.frame.origin.x < 15) {
                    numberLabel = textField;
                } else {
                    titleLabel = textField;
                }
            }
        }
        
        if (i < _currentIndex) {
            // Completed step
            if (numberLabel) {
                numberLabel.textColor = [NSColor colorWithCalibratedRed:0.6 green:0.6 blue:0.6 alpha:1.0];
                numberLabel.font = [NSFont systemFontOfSize:11.0];
            }
            if (titleLabel) {
                titleLabel.textColor = [NSColor colorWithCalibratedRed:0.6 green:0.6 blue:0.6 alpha:1.0];
                titleLabel.font = [NSFont systemFontOfSize:12.0];
            }
        } else if (i == _currentIndex) {
            // Current step
            if (numberLabel) {
                numberLabel.textColor = [NSColor colorWithCalibratedRed:0.0 green:0.0 blue:0.0 alpha:1.0];
                numberLabel.font = [NSFont boldSystemFontOfSize:11.0];
            }
            if (titleLabel) {
                titleLabel.textColor = [NSColor colorWithCalibratedRed:0.0 green:0.0 blue:0.0 alpha:1.0];
                titleLabel.font = [NSFont boldSystemFontOfSize:12.0];
            }
        } else {
            // Future step
            if (numberLabel) {
                numberLabel.textColor = [NSColor colorWithCalibratedRed:0.4 green:0.4 blue:0.4 alpha:1.0];
                numberLabel.font = [NSFont systemFontOfSize:11.0];
            }
            if (titleLabel) {
                titleLabel.textColor = [NSColor colorWithCalibratedRed:0.4 green:0.4 blue:0.4 alpha:1.0];
                titleLabel.font = [NSFont systemFontOfSize:12.0];
            }
        }
    }
}

- (void)goToNextStep {
    if ((NSUInteger)_currentIndex < _stepsArray.count - 1) {
        _currentIndex++;
        [self showCurrentStep];
    } else {
        [self finishAssistant];
    }
}

- (void)goToPreviousStep {
    if (_currentIndex > 0) {
        _currentIndex--;
        [self showCurrentStep];
    }
}

- (void)goToStepAtIndex:(NSInteger)index {
    if (index >= 0 && (NSUInteger)index < _stepsArray.count && index != _currentIndex) {
        _currentIndex = index;
        [self showCurrentStep];
    }
}

- (void)finishAssistant {
    if ([self.delegate respondsToSelector:@selector(assistantWindow:didFinishWithResult:)]) {
        [self.delegate assistantWindow:self didFinishWithResult:YES];
    }
    if ([self.delegate respondsToSelector:@selector(assistantWindowWillFinish:)]) {
        [self.delegate assistantWindowWillFinish:self];
    }
    if ([self.delegate respondsToSelector:@selector(assistantWindowDidFinish:)]) {
        [self.delegate assistantWindowDidFinish:self];
    }
    [self close];
}

- (void)cancelAssistant {
    BOOL shouldCancel = YES;
    if ([self.delegate respondsToSelector:@selector(assistantWindow:shouldCancelWithConfirmation:)]) {
        shouldCancel = [self.delegate assistantWindow:self shouldCancelWithConfirmation:YES];
    }
    
    if (shouldCancel) {
        if ([self.delegate respondsToSelector:@selector(assistantWindowDidCancel:)]) {
            [self.delegate assistantWindowDidCancel:self];
        }
        [self close];
    }
}

#pragma mark - UI Updates

- (void)updateNavigationButtons {
    // Delegate to the appropriate layout-specific method
    if (_layoutStyle == GSAssistantLayoutStyleInstaller) {
        [self updateInstallerNavigationButtons];
    } else {
        [self updateDefaultNavigationButtons];
    }
}

- (void)updateDefaultNavigationButtons {
    id<GSAssistantStepProtocol> step = [self currentStep];
    if (!step) return;
    
    BOOL canContinue = [step canContinue];
    BOOL isLastStep = ((NSUInteger)_currentIndex == _stepsArray.count - 1);
    
    _continueButton.enabled = canContinue;
    
    if ([step respondsToSelector:@selector(continueButtonTitle)]) {
        NSString *customTitle = [step continueButtonTitle];
        if (customTitle) {
            _continueButton.title = customTitle;
        } else {
            _continueButton.title = isLastStep ? @"Finish" : @"Continue";
        }
    } else {
        _continueButton.title = isLastStep ? @"Finish" : @"Continue";
    }
    
    BOOL canGoBack = (_currentIndex > 0);
    if ([step respondsToSelector:@selector(canGoBack)]) {
        canGoBack = canGoBack && [step canGoBack];
    }
    
    _backButton.enabled = canGoBack;
    _backButton.hidden = !canGoBack;
    
    if ([step respondsToSelector:@selector(backButtonTitle)]) {
        NSString *customTitle = [step backButtonTitle];
        if (customTitle) {
            _backButton.title = customTitle;
        } else {
            _backButton.title = @"Go Back";
        }
    } else {
        _backButton.title = @"Go Back";
    }
    
    _cancelButton.hidden = !_allowsCancel;
}

- (void)updateProgressBar {
    // Basic implementation
}

- (void)updateStepInfo {
    id<GSAssistantStepProtocol> step = [self currentStep];
    if (!step) return;
    
    _stepTitleLabel.stringValue = [step stepTitle] ?: @"";
    _stepDescriptionLabel.stringValue = [step stepDescription] ?: @"";
}

#pragma mark - Error and Success Pages

- (void)showErrorPageWithMessage:(NSString *)message {
    [self showErrorPageWithTitle:@"Error" message:message];
}

- (void)showErrorPageWithTitle:(NSString *)title message:(NSString *)message {
    GSCompletionStep *errorStep = [[GSCompletionStep alloc] initWithCompletionMessage:message success:NO];
    errorStep.title = title;
    errorStep.stepDescription = @"An error occurred during the process.";
    
    [self.steps removeAllObjects];
    [self addStep:errorStep];
    
    _currentIndex = 0;
    [self showCurrentStep];
    
    [errorStep release];
}

- (void)showSuccessPageWithTitle:(NSString *)title message:(NSString *)message {
    GSCompletionStep *successStep = [[GSCompletionStep alloc] initWithCompletionMessage:message success:YES];
    successStep.title = title;
    successStep.stepDescription = @"The process completed successfully.";
    
    [self.steps removeAllObjects];
    [self addStep:successStep];
    
    _currentIndex = 0;
    [self showCurrentStep];
    
    [successStep release];
}

#pragma mark - Installer Layout Methods

- (void)setupInstallerSidebarView {
    NSRect sidebarFrame = NSMakeRect(0, GSAssistantInstallerButtonAreaHeight, 
                                   GSAssistantInstallerSidebarWidth, 
                                   _windowHeight - GSAssistantInstallerButtonAreaHeight);
    
    _sidebarView = [[GSColoredBackgroundView alloc] initWithFrame:sidebarFrame];
    [(GSColoredBackgroundView *)_sidebarView setBackgroundColor:
        [NSColor colorWithCalibratedRed:0.957 green:0.965 blue:0.973 alpha:1.0]];
    [_contentView addSubview:_sidebarView];
    
    // Background logo if available
    if (_assistantIcon) {
        NSRect logoFrame = NSMakeRect(25, 100, 120, 120);
        _sidebarImageView = [[NSImageView alloc] initWithFrame:logoFrame];
        [_sidebarImageView setImage:_assistantIcon];
        [_sidebarImageView setImageAlignment:NSImageAlignCenter];
        [_sidebarImageView setImageScaling:NSImageScaleProportionallyUpOrDown];
        [_sidebarImageView setAlphaValue:0.1]; // Very subtle
        [_sidebarView addSubview:_sidebarImageView];
    }
    
    // Create step indicators
    [self createInstallerStepIndicators];
    
    // Add separator line
    NSRect separatorFrame = NSMakeRect(GSAssistantInstallerSidebarWidth - 1, 0, 1, 
                                     _windowHeight - GSAssistantInstallerButtonAreaHeight);
    GSColoredBackgroundView *separatorView = [[GSColoredBackgroundView alloc] initWithFrame:separatorFrame];
    [separatorView setBackgroundColor:[NSColor colorWithCalibratedRed:0.816 green:0.816 blue:0.816 alpha:1.0]];
    [_sidebarView addSubview:separatorView];
    [separatorView release];
    
    NSLog(@"[GSAssistantWindow] Installer sidebar setup complete");
}

- (void)setupInstallerContentView {
    NSRect contentFrame = NSMakeRect(GSAssistantInstallerSidebarWidth, GSAssistantInstallerButtonAreaHeight,
                                   _windowWidth - GSAssistantInstallerSidebarWidth, 
                                   _windowHeight - GSAssistantInstallerButtonAreaHeight);
    
    _mainContentView = [[GSColoredBackgroundView alloc] initWithFrame:contentFrame];
    [(GSColoredBackgroundView *)_mainContentView setBackgroundColor:[NSColor whiteColor]];
    [_contentView addSubview:_mainContentView];
    
    NSLog(@"[GSAssistantWindow] Installer content area setup complete");
}

- (void)setupInstallerButtonArea {
    NSRect buttonFrame = NSMakeRect(0, 0, _windowWidth, GSAssistantInstallerButtonAreaHeight);
    _installerButtonAreaView = [[GSColoredBackgroundView alloc] initWithFrame:buttonFrame];
    [(GSColoredBackgroundView *)_installerButtonAreaView setBackgroundColor:
        [NSColor colorWithCalibratedRed:0.941 green:0.949 blue:0.961 alpha:1.0]];
    [_contentView addSubview:_installerButtonAreaView];
    
    // Add top separator line
    NSRect separatorFrame = NSMakeRect(0, GSAssistantInstallerButtonAreaHeight - 1, _windowWidth, 1);
    GSColoredBackgroundView *separatorView = [[GSColoredBackgroundView alloc] initWithFrame:separatorFrame];
    [separatorView setBackgroundColor:[NSColor colorWithCalibratedRed:0.816 green:0.816 blue:0.816 alpha:1.0]];
    [_installerButtonAreaView addSubview:separatorView];
    [separatorView release];
    
    // Create installer buttons
    CGFloat buttonY = (GSAssistantInstallerButtonAreaHeight - 24) / 2;
    
    // Options button (left side, hidden by default)
    NSRect optionsFrame = NSMakeRect(20, buttonY, 80, 24);
    _optionsButton = [[NSButton alloc] initWithFrame:optionsFrame];
    [_optionsButton setTitle:@"Options..."];
    [_optionsButton setBezelStyle:NSRoundedBezelStyle];
    [_optionsButton setTarget:self];
    [_optionsButton setAction:@selector(optionsButtonClicked:)];
    [_optionsButton setHidden:YES];
    [_installerButtonAreaView addSubview:_optionsButton];
    
    // Continue button (right side)
    NSRect continueFrame = NSMakeRect(_windowWidth - 20 - 100, buttonY, 100, 24);
    _continueButton = [[NSButton alloc] initWithFrame:continueFrame];
    [_continueButton setTitle:@"Continue"];
    [_continueButton setBezelStyle:NSRoundedBezelStyle];
    [_continueButton setKeyEquivalent:@"\r"];
    [_continueButton setTarget:self];
    [_continueButton setAction:@selector(continueClicked:)];
    [_continueButton setEnabled:NO]; // Disabled by default until step allows it
    [_installerButtonAreaView addSubview:_continueButton];
    
    // Back button (left of continue button)
    NSRect backFrame = NSMakeRect(_windowWidth - 20 - 100 - 12 - 80, buttonY, 80, 24);
    _backButton = [[NSButton alloc] initWithFrame:backFrame];
    [_backButton setTitle:@"Go Back"];
    [_backButton setBezelStyle:NSRoundedBezelStyle];
    [_backButton setTarget:self];
    [_backButton setAction:@selector(backClicked:)];
    [_backButton setEnabled:NO]; // Disabled initially
    [_installerButtonAreaView addSubview:_backButton];
    
    NSLog(@"[GSAssistantWindow] Installer button area setup complete");
}

- (void)createInstallerStepIndicators {
    CGFloat startY = [_sidebarView frame].size.height - 80; // Start lower from top with more margin
    CGFloat stepHeight = 26; // 24px height + 2px spacing
    
    for (NSInteger i = 0; i < (NSInteger)_stepsArray.count; i++) {
        id<GSAssistantStepProtocol> step = _stepsArray[i];
        CGFloat yPosition = startY - (i * stepHeight);
        
        // Create step container view
        NSRect stepFrame = NSMakeRect(10, yPosition, GSAssistantInstallerSidebarWidth - 20, 24);
        NSView *stepView = [[NSView alloc] initWithFrame:stepFrame];
        
        // Create circle indicator (simple colored box for GNUstep compatibility)
        NSRect circleFrame = NSMakeRect(0, 2, 20, 20);
        GSColoredBackgroundView *circleView = [[GSColoredBackgroundView alloc] initWithFrame:circleFrame];
        [circleView setBackgroundColor:[NSColor grayColor]]; // Default gray
        
        // Create step label
        NSRect labelFrame = NSMakeRect(30, 0, stepFrame.size.width - 35, 24);
        NSTextField *stepLabel = [[NSTextField alloc] initWithFrame:labelFrame];
        [stepLabel setStringValue:[step stepTitle]];
        [stepLabel setBezeled:NO];
        [stepLabel setDrawsBackground:NO];
        [stepLabel setEditable:NO];
        [stepLabel setSelectable:NO];
        [stepLabel setBordered:NO];  // Remove border
        [stepLabel setFont:[NSFont systemFontOfSize:13]];
        [stepLabel setTextColor:[NSColor blackColor]];
        
        [stepView addSubview:circleView];
        [stepView addSubview:stepLabel];
        [_sidebarView addSubview:stepView];
        [_stepIndicatorViews addObject:stepView];
        
        [circleView release];
        [stepLabel release];
        [stepView release];
    }
    
    NSLog(@"[GSAssistantWindow] Created %lu step indicators", (unsigned long)_stepIndicatorViews.count);
}

- (void)updateInstallerStepIndicators {
    for (NSInteger i = 0; i < (NSInteger)_stepIndicatorViews.count; i++) {
        NSView *stepView = _stepIndicatorViews[i];
        GSColoredBackgroundView *circleView = (GSColoredBackgroundView *)[[stepView subviews] objectAtIndex:0];
        NSTextField *labelField = [[stepView subviews] objectAtIndex:1];
        
        if (i < _currentIndex) {
            // Completed step - blue circle
            [circleView setBackgroundColor:[NSColor colorWithCalibratedRed:0.0 green:0.478 blue:1.0 alpha:1.0]];
            [labelField setTextColor:[NSColor blackColor]];
            [labelField setFont:[NSFont systemFontOfSize:13]];
        } else if (i == _currentIndex) {
            // Current step - blue circle, bold text
            [circleView setBackgroundColor:[NSColor colorWithCalibratedRed:0.0 green:0.478 blue:1.0 alpha:1.0]];
            [labelField setTextColor:[NSColor blackColor]];
            [labelField setFont:[NSFont boldSystemFontOfSize:13]];
        } else {
            // Future step - light gray
            [circleView setBackgroundColor:[NSColor colorWithCalibratedRed:0.9 green:0.9 blue:0.9 alpha:1.0]];
            [labelField setTextColor:[NSColor colorWithCalibratedRed:0.4 green:0.4 blue:0.4 alpha:1.0]];
            [labelField setFont:[NSFont systemFontOfSize:13]];
        }
    }
}

- (void)setupInstallerStepContent {
    // Clear existing content
    for (NSView *subview in [_mainContentView subviews]) {
        [subview removeFromSuperview];
    }
    
    if (_currentIndex < (NSInteger)_stepsArray.count) {
        id<GSAssistantStepProtocol> currentStep = _stepsArray[_currentIndex];
        
        // Create step title - moved much lower from height-60 to height-40 for proper positioning
        NSRect titleFrame = NSMakeRect(40, [_mainContentView frame].size.height - 40, 
                                     [_mainContentView frame].size.width - 80, 30);
        NSTextField *stepTitleField = [[NSTextField alloc] initWithFrame:titleFrame];
        [stepTitleField setStringValue:[currentStep stepTitle]];
        [stepTitleField setBezeled:NO];
        [stepTitleField setBordered:NO];
        [stepTitleField setDrawsBackground:NO];
        [stepTitleField setEditable:NO];
        [stepTitleField setSelectable:NO];
        [stepTitleField setFont:[NSFont boldSystemFontOfSize:20]];
        [stepTitleField setTextColor:[NSColor blackColor]];
        [_mainContentView addSubview:stepTitleField];
        [stepTitleField release];
        
        // Add step content view - moved much lower from top margin 110 to 80
        NSView *stepContentView = [currentStep stepView];
        if (stepContentView) {
            NSRect contentFrame = NSMakeRect(40, 20, 
                                           [_mainContentView frame].size.width - 80,
                                           [_mainContentView frame].size.height - 80); // Increased from 110 to 80
            [stepContentView setFrame:contentFrame];
            [_mainContentView addSubview:stepContentView];
        }
    }
}

- (void)updateInstallerNavigationButtons {
    id<GSAssistantStepProtocol> step = [self currentStep];
    if (!step) return;
    
    NSLog(@"[GSAssistantWindow] Updating installer navigation buttons for step %ld", (long)_currentIndex);
    
    BOOL canContinue = [step canContinue];
    BOOL isLastStep = ((NSUInteger)_currentIndex == _stepsArray.count - 1);
    
    _continueButton.enabled = canContinue;
    
    // Set continue button title
    if ([step respondsToSelector:@selector(continueButtonTitle)]) {
        NSString *customTitle = [step continueButtonTitle];
        if (customTitle) {
            _continueButton.title = customTitle;
        } else {
            _continueButton.title = isLastStep ? @"Finish" : @"Continue";
        }
    } else {
        _continueButton.title = isLastStep ? @"Finish" : @"Continue";
    }
    
    // Set continue button as default
    [_continueButton setKeyEquivalent:@"\r"];
    
    // Back button logic
    BOOL canGoBack = (_currentIndex > 0);
    if ([step respondsToSelector:@selector(canGoBack)]) {
        canGoBack = canGoBack && [step canGoBack];
    }
    
    _backButton.enabled = canGoBack;
    
    if ([step respondsToSelector:@selector(backButtonTitle)]) {
        NSString *customBackTitle = [step backButtonTitle];
        if (customBackTitle) {
            _backButton.title = customBackTitle;
        } else {
            _backButton.title = @"Go Back";
        }
    } else {
        _backButton.title = @"Go Back";
    }
    
    // Options button is hidden by default
    _optionsButton.hidden = YES;
}

#pragma mark - Installer Button Actions

- (void)continueClicked:(id)sender {
    NSLog(@"[GSAssistantWindow] Continue button clicked from installer layout");
    [self goToNextStep];
}

- (void)backClicked:(id)sender {
    NSLog(@"[GSAssistantWindow] Back button clicked from installer layout");
    [self goToPreviousStep];
}

- (void)optionsButtonClicked:(id)sender {
    NSLog(@"[GSAssistantWindow] Options button clicked");
    // Handle options - to be implemented based on specific step needs
}

@end
