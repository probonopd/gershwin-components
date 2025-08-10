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

// Rectangular translucent card view for installer content area (no rounded corners)
@interface GSInstallerCardView : NSView
@property (nonatomic, retain) NSColor *fillColor;   // With alpha, e.g., white 0.90–0.92
@property (nonatomic, retain) NSColor *strokeColor; // Light gray stroke
@property (nonatomic, assign) CGFloat cornerRadius; // kept for compatibility, set to 0.0
@end

@implementation GSInstallerCardView
- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        _fillColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.33] retain];
        _strokeColor = [[NSColor colorWithCalibratedWhite:0.72 alpha:1.0] retain];
        _cornerRadius = 0.0; // rectangular
    }
    return self;
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect bounds = self.bounds;

    // Rectangular card, no shadow, subtle 1px border
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:NSInsetRect(bounds, 0.5, 0.5)];

    [_fillColor setFill];
    [path fill];

    [_strokeColor setStroke];
    [path setLineWidth:1.0];
    [path stroke];
}
- (void)dealloc {
    [_fillColor release];
    [_strokeColor release];
    [super dealloc];
}
@end

// 10.3-style step indicator bullet view
@interface GSStepBulletView : NSView {
    NSInteger _state; // 0=future, 1=current, 2=completed
}
@property (nonatomic, assign) NSInteger state;
@end

@implementation GSStepBulletView
- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        _state = 0;
    }
    return self;
}
- (void)setState:(NSInteger)state { _state = state; [self setNeedsDisplay:YES]; }
- (NSInteger)state { return _state; }
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect b = NSInsetRect(self.bounds, 1.0, 1.0);
    CGFloat d = MIN(NSWidth(b), NSHeight(b));
    NSRect circle = NSMakeRect(NSMidX(b)-d/2.0, NSMidY(b)-d/2.0, d, d);
    NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:circle];

    NSColor *stroke = [NSColor colorWithCalibratedWhite:0.65 alpha:1.0];
    NSColor *fill   = [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];

    if (_state == 1) { // current
        fill = [NSColor colorWithCalibratedRed:0.0 green:0.478 blue:1.0 alpha:1.0];
        stroke = [NSColor colorWithCalibratedWhite:0.35 alpha:1.0];
    } else if (_state == 2) { // completed
        fill = [NSColor colorWithCalibratedWhite:0.55 alpha:1.0];
        stroke = [NSColor colorWithCalibratedWhite:0.45 alpha:1.0];
    }

    [fill setFill];
    [path fill];
    [stroke setStroke];
    [path setLineWidth:1.0];
    [path stroke];
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

// New: installer content card & watermark/title refs
@property (nonatomic, strong) GSInstallerCardView *installerContentCardView;
@property (nonatomic, strong) NSImageView *contentWatermarkImageView;
@property (nonatomic, strong) NSTextField *installerStepTitleField;
@property (nonatomic, strong) NSTextField *installerStepDescriptionField;

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
    [_installerContentCardView release];
    [_contentWatermarkImageView release];
    [_installerStepTitleField release];
    [_installerStepDescriptionField release];
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
    
    // Make sure the application quits when window is closed
    [window setReleasedWhenClosed:YES];
    window.delegate = self;
    
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
    
    // Main title
    _titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 280, 460, 30)];
    _titleLabel.editable = NO;
    _titleLabel.selectable = NO;
    _titleLabel.bordered = NO;
    _titleLabel.bezeled = NO;
    _titleLabel.drawsBackground = NO;
    _titleLabel.backgroundColor = [NSColor clearColor];
    _titleLabel.font = [NSFont boldSystemFontOfSize:20.0];
    _titleLabel.stringValue = _assistantTitle ?: @"Setup Assistant";
    [_mainContentView addSubview:_titleLabel];
    
    // Step title
    _stepTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 212, 420, 24)];
    _stepTitleLabel.editable = NO;
    _stepTitleLabel.selectable = NO;
    _stepTitleLabel.bordered = NO;
    _stepTitleLabel.bezeled = NO;
    _stepTitleLabel.drawsBackground = NO;
    _stepTitleLabel.backgroundColor = [NSColor clearColor];
    _stepTitleLabel.font = [NSFont boldSystemFontOfSize:16.0];
    [_mainContentView addSubview:_stepTitleLabel];
    
    // Step description
    _stepDescriptionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 220, 430, 20)];
    _stepDescriptionLabel.editable = NO;
    _stepDescriptionLabel.selectable = NO;
    _stepDescriptionLabel.bordered = NO;
    _stepDescriptionLabel.bezeled = NO;
    _stepDescriptionLabel.drawsBackground = NO;
    _stepDescriptionLabel.backgroundColor = [NSColor clearColor];
    _stepDescriptionLabel.font = [NSFont systemFontOfSize:13.0];
    _stepDescriptionLabel.textColor = [NSColor colorWithCalibratedRed:0.4 green:0.4 blue:0.4 alpha:1.0];
    [_mainContentView addSubview:_stepDescriptionLabel];
    
    // Step content area
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
    
    // Cancel button with standard margins and height (20px from bottom)
    _cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(24, 20, 85, 24)];
    _cancelButton.title = @"Cancel";
    _cancelButton.bezelStyle = NSRoundedBezelStyle;
    _cancelButton.font = [NSFont systemFontOfSize:13.0];
    _cancelButton.target = self;
    _cancelButton.action = @selector(cancelButtonClicked:);
    [_navigationView addSubview:_cancelButton];
    
    // Back button with standard spacing and height (20px from bottom)
    _backButton = [[NSButton alloc] initWithFrame:NSMakeRect(494, 20, 85, 24)];
    _backButton.title = @"Go Back";
    _backButton.bezelStyle = NSRoundedBezelStyle;
    _backButton.font = [NSFont systemFontOfSize:13.0];
    _backButton.target = self;
    _backButton.action = @selector(backButtonClicked:);
    [_navigationView addSubview:_backButton];
    
    // Continue button - standard height and spacing (20px from bottom)
    _continueButton = [[NSButton alloc] initWithFrame:NSMakeRect(591, 20, 85, 24)];
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
    
    // Sidebar should be visually flat: no colored background and no separator line here
    _sidebarView = [[NSView alloc] initWithFrame:sidebarFrame];

    // Add a single watermark for the whole dialog, behind everything
    if (_assistantIcon && !_contentWatermarkImageView) {
        // Background area excludes window titlebar; position relative to contentView
        CGFloat availableH = _windowHeight - GSAssistantInstallerButtonAreaHeight;
        // Large but constrained size based on height
        CGFloat wmSize = MIN(availableH * 0.80, 480.0);
        CGFloat wmX = -80.0; // near window left edge
        CGFloat wmY = GSAssistantInstallerButtonAreaHeight + (availableH - wmSize) / 2.0 - 40.0;
        NSRect wmFrame = NSMakeRect(wmX, wmY, wmSize, wmSize);
        _contentWatermarkImageView = [[NSImageView alloc] initWithFrame:wmFrame];
        [_contentWatermarkImageView setImage:_assistantIcon];
        [_contentWatermarkImageView setImageScaling:NSImageScaleProportionallyUpOrDown];
        [_contentWatermarkImageView setImageAlignment:NSImageAlignCenter];
        // Workaround: force faint alpha by compositing image with alpha
        NSImage *icon = _assistantIcon;
        NSImage *faintIcon = [[NSImage alloc] initWithSize:[icon size]];
        [faintIcon lockFocus];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.0] set];
        NSRectFill(NSMakeRect(0,0,[icon size].width,[icon size].height));
        [icon drawInRect:NSMakeRect(0,0,[icon size].width,[icon size].height)
#if defined(NSCompositingOperationSourceOver)
                fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
#else
                fromRect:NSZeroRect
                operation:NSCompositeSourceOver
#endif
                fraction:0.5];
        [faintIcon unlockFocus];
        [_contentWatermarkImageView setImage:faintIcon];
        [faintIcon release];
        [_contentWatermarkImageView setAlphaValue:1.0];
        [_contentWatermarkImageView setAutoresizingMask:(NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin)];
        // Place at the very back so it shines through both sidebar and content card
        [_contentView addSubview:_contentWatermarkImageView positioned:NSWindowBelow relativeTo:nil];
        NSLog(@"[GSAssistantWindow] Global watermark added (whole dialog), frame %@", NSStringFromRect(wmFrame));
    }

    [_contentView addSubview:_sidebarView];
    
    // Create step indicators
    [self createInstallerStepIndicators];
    
    NSLog(@"[GSAssistantWindow] Installer sidebar setup complete (no background, no separators)");
}

- (void)setupInstallerContentView {
    NSRect contentFrame = NSMakeRect(GSAssistantInstallerSidebarWidth, GSAssistantInstallerButtonAreaHeight,
                                   _windowWidth - GSAssistantInstallerSidebarWidth, 
                                   _windowHeight - GSAssistantInstallerButtonAreaHeight);

    // Content area should be flat/transparent
    _mainContentView = [[NSView alloc] initWithFrame:contentFrame];
    [_contentView addSubview:_mainContentView];

    NSLog(@"[GSAssistantWindow] Content view setup. assistantIcon=%@", _assistantIcon);

    CGFloat cw = [_mainContentView frame].size.width;
    CGFloat ch = [_mainContentView frame].size.height;

    // Space around the semi-transparent card - optimize for maximum vertical space
    CGFloat sideInset = 24.0; // Standard side margins
    CGFloat bottomInset = 20.0; // Standard bottom margin
    // Reserve room for the step title
    CGFloat topInsetForTitle = 72.0;

    NSRect cardFrame = NSMakeRect(sideInset, bottomInset, cw - (2*sideInset), ch - (bottomInset + topInsetForTitle));

    // Card first (rectangular, semi-transparent, subtle border)
    _installerContentCardView = [[GSInstallerCardView alloc] initWithFrame:cardFrame];
    [_installerContentCardView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [_mainContentView addSubview:_installerContentCardView];

    NSLog(@"[GSAssistantWindow] Installer content area setup complete (card only; watermark handled globally). card=%@", _installerContentCardView);
}

- (void)setupInstallerButtonArea {
    NSRect buttonFrame = NSMakeRect(0, 0, _windowWidth, GSAssistantInstallerButtonAreaHeight);
    // Button area should be flat: no background and no separator line
    _installerButtonAreaView = [[NSView alloc] initWithFrame:buttonFrame];
    [_contentView addSubview:_installerButtonAreaView];
    
    // Create installer buttons per spec - 20px from bottom edge
    CGFloat buttonY = 20.0; // bottom margin 20px as per spacing guidelines
    
    // Options button (left side, hidden by default) with standard margins
    NSRect optionsFrame = NSMakeRect(24, buttonY, 80, 24);
    _optionsButton = [[NSButton alloc] initWithFrame:optionsFrame];
    [_optionsButton setTitle:@"Options..."];
    [_optionsButton setBezelStyle:NSRoundedBezelStyle];
    [_optionsButton setTarget:self];
    [_optionsButton setAction:@selector(optionsButtonClicked:)];
    [_optionsButton setHidden:YES];
    [_installerButtonAreaView addSubview:_optionsButton];
    
    // Continue button (right side) 100x24, right edge 24px
    NSRect continueFrame = NSMakeRect(_windowWidth - 24 - 100, buttonY, 100, 24);
    _continueButton = [[NSButton alloc] initWithFrame:continueFrame];
    [_continueButton setTitle:@"Continue"];
    [_continueButton setBezelStyle:NSRoundedBezelStyle];
    [_continueButton setKeyEquivalent:@"\r"];
    [_continueButton setTarget:self];
    [_continueButton setAction:@selector(continueClicked:)];
    [_continueButton setEnabled:NO];
    [_installerButtonAreaView addSubview:_continueButton];
    
    // Back button (left of continue by 12px), 80x24
    NSRect backFrame = NSMakeRect(_windowWidth - 24 - 100 - 12 - 80, buttonY, 80, 24);
    _backButton = [[NSButton alloc] initWithFrame:backFrame];
    [_backButton setTitle:@"Go Back"];
    [_backButton setBezelStyle:NSRoundedBezelStyle];
    [_backButton setTarget:self];
    [_backButton setAction:@selector(backClicked:)];
    [_backButton setEnabled:NO];
    [_installerButtonAreaView addSubview:_backButton];
    
    NSLog(@"[GSAssistantWindow] Installer button area setup complete (flat)");
}

- (void)createInstallerStepIndicators {
    CGFloat startY = [_sidebarView frame].size.height - 36; // top inset 36px
    CGFloat stepPitch = 26.0; // 24 height + 2 gap

    for (NSInteger i = 0; i < (NSInteger)_stepsArray.count; i++) {
        id<GSAssistantStepProtocol> step = _stepsArray[i];
        CGFloat yPosition = startY - 45 - (i * stepPitch);

        NSRect stepFrame = NSMakeRect(6, yPosition - 12, GSAssistantInstallerSidebarWidth - 12 - 6, 24);
        NSView *stepRow = [[NSView alloc] initWithFrame:stepFrame];

        // Bullet 16x16 at x=8
        GSStepBulletView *bullet = [[GSStepBulletView alloc] initWithFrame:NSMakeRect(8, 8, 16, 16)];
        [bullet setState:(i == 0 ? 1 : 0)];

        // Label
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(32, 1, stepFrame.size.width - 36, 20)];
        [label setStringValue:[step stepTitle]];
        [label setBezeled:NO];
        [label setDrawsBackground:NO];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setBordered:NO];
        [label setFont:[NSFont systemFontOfSize:12]];
        [label setTextColor:[NSColor colorWithCalibratedWhite:0.25 alpha:1.0]];

        [stepRow addSubview:bullet];
        [stepRow addSubview:label];
        [_sidebarView addSubview:stepRow];
        [_stepIndicatorViews addObject:stepRow];

        [bullet release];
        [label release];
        [stepRow release];
    }

    NSLog(@"[GSAssistantWindow] Created %lu step indicators", (unsigned long)_stepIndicatorViews.count);
}

- (void)updateInstallerStepIndicators {
    for (NSInteger i = 0; i < (NSInteger)_stepIndicatorViews.count; i++) {
        NSView *row = [_stepIndicatorViews objectAtIndex:i];
        if ([[row subviews] count] < 2) continue;
        GSStepBulletView *bullet = (GSStepBulletView *)[[row subviews] objectAtIndex:0];
        NSTextField *label = (NSTextField *)[[row subviews] objectAtIndex:1];

        if (i < _currentIndex) {
            [bullet setState:2];
            [label setTextColor:[NSColor colorWithCalibratedWhite:0.5 alpha:1.0]];
            [label setFont:[NSFont systemFontOfSize:12]];
        } else if (i == _currentIndex) {
            [bullet setState:1];
            [label setTextColor:[NSColor blackColor]];
            [label setFont:[NSFont boldSystemFontOfSize:12]];
        } else {
            [bullet setState:0];
            [label setTextColor:[NSColor colorWithCalibratedWhite:0.6 alpha:1.0]];
            [label setFont:[NSFont systemFontOfSize:12]];
        }
    }
}

- (void)setupInstallerStepContent {
    // Remove previous title/description fields if any
    if (_installerStepTitleField) { [_installerStepTitleField removeFromSuperview]; [_installerStepTitleField release]; _installerStepTitleField = nil; }
    if (_installerStepDescriptionField) { [_installerStepDescriptionField removeFromSuperview]; [_installerStepDescriptionField release]; _installerStepDescriptionField = nil; }

    // Clear card subviews but keep any future background layers
    if (_installerContentCardView) {
        NSArray *subviews = [[_installerContentCardView.subviews copy] autorelease];
        for (NSView *sub in subviews) {
            [sub removeFromSuperview];
        }
    }

    if (_currentIndex < (NSInteger)_stepsArray.count) {
        id<GSAssistantStepProtocol> currentStep = _stepsArray[_currentIndex];

        CGFloat contentWidth = [_mainContentView frame].size.width;   // full content width

        // Title above the card - position to match the standard top margin
        NSRect titleFrame = NSMakeRect(24, 320, contentWidth - 48, 26);
        _installerStepTitleField = [[NSTextField alloc] initWithFrame:titleFrame];
        [_installerStepTitleField setStringValue:[currentStep stepTitle] ?: @""];
        [_installerStepTitleField setBezeled:NO];
        [_installerStepTitleField setBordered:NO];
        [_installerStepTitleField setDrawsBackground:NO];
        [_installerStepTitleField setEditable:NO];
        [_installerStepTitleField setSelectable:NO];
        [_installerStepTitleField setFont:[NSFont boldSystemFontOfSize:20]];
        [_installerStepTitleField setTextColor:[NSColor blackColor]];
        [_mainContentView addSubview:_installerStepTitleField];

        // Optional description INSIDE the card, top with padding
        NSString *desc = nil;
        if ([currentStep respondsToSelector:@selector(stepDescription)]) {
            desc = [currentStep stepDescription];
        }
        CGFloat descBlockHeight = 0.0;
        if (desc && [desc length] > 0) {
            NSRect inner = NSInsetRect(_installerContentCardView.bounds, 12.0, 12.0);
            NSRect descFrame = NSMakeRect(inner.origin.x, inner.origin.y + inner.size.height - 18.0, inner.size.width, 16.0);
            _installerStepDescriptionField = [[NSTextField alloc] initWithFrame:descFrame];
            [_installerStepDescriptionField setStringValue:desc];
            [_installerStepDescriptionField setBezeled:NO];
            [_installerStepDescriptionField setBordered:NO];
            [_installerStepDescriptionField setDrawsBackground:NO];
            [_installerStepDescriptionField setEditable:NO];
            [_installerStepDescriptionField setSelectable:NO];
            [_installerStepDescriptionField setFont:[NSFont systemFontOfSize:12]];
            [_installerStepDescriptionField setTextColor:[NSColor colorWithCalibratedWhite:0.25 alpha:1.0]];
            [_installerContentCardView addSubview:_installerStepDescriptionField];
            descBlockHeight = 20.0; // label height + minimal spacing
        }

        // Place step view below the description inside the card with optimized padding to maximize vertical space
        NSView *stepContentView = [currentStep stepView];
        if (stepContentView) {
            NSRect inner = NSInsetRect(_installerContentCardView.bounds, 12.0, 12.0);
            NSRect innerAdjusted = NSMakeRect(inner.origin.x,
                                              inner.origin.y,
                                              inner.size.width,
                                              inner.size.height - descBlockHeight);
            [stepContentView setFrame:innerAdjusted];
            [_installerContentCardView addSubview:stepContentView];
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

#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification {
    NSLog(@"[GSAssistantWindow] Window closing, terminating application");
    [NSApp terminate:nil];
}

@end
