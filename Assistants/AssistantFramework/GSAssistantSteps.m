#import "GSAssistantFramework.h"

// Base Assistant Step Implementation
@implementation GSAssistantStep

- (instancetype)initWithTitle:(NSString *)title 
                  description:(NSString *)description 
                         view:(NSView *)view {
    NSLog(@"[GSAssistantStep] Initializing step with title: '%@', description: '%@', view: %@", title, description, view);
    self = [super init];
    if (self) {
        _title = [title copy];
        _stepDescription = [description copy];
        _view = view;
        _stepType = GSAssistantStepTypeConfiguration; // Default type
        _canProceed = NO; // Disabled by default - steps must explicitly enable continuation
        _canReturn = YES;
        _progress = 0.0;
    }
    NSLog(@"[GSAssistantStep] Step initialized successfully");
    return self;
}

// GSAssistantStepProtocol implementation
- (NSString *)stepTitle {
    return self.title;
}

- (NSString *)stepDescription {
    return _stepDescription;
}

- (NSView *)stepView {
    NSLog(@"[GSAssistantStep] stepView called on step: %@", self);
    NSLog(@"[GSAssistantStep] Returning view: %@ with frame: %@", self.view, NSStringFromRect(self.view.frame));
    return self.view;
}

- (BOOL)canContinue {
    return self.canProceed;
}

@end

@implementation GSIntroductionStep

- (instancetype)initWithTitle:(NSString *)title 
                  description:(NSString *)description 
                         view:(NSView *)view {
    self = [super initWithTitle:title description:description view:view];
    if (self) {
        self.stepType = GSAssistantStepTypeIntroduction;
        self.customContinueTitle = @"Get Started";
        self.canReturn = NO; // Usually can't go back from introduction
        self.canProceed = YES; // Introduction steps can usually continue immediately
    }
    return self;
}

- (instancetype)initWithWelcomeMessage:(NSString *)welcomeMessage 
                           featureList:(NSArray<NSString *> *)featureList {
    NSView *introView = [self createIntroductionViewWithMessage:welcomeMessage features:featureList];
    self = [super initWithTitle:@"Welcome" description:welcomeMessage view:introView];
    if (self) {
        self.stepType = GSAssistantStepTypeIntroduction;
        self.customContinueTitle = @"Get Started";
        self.canReturn = NO;
        self.canProceed = YES; // Introduction steps can usually continue immediately
        _welcomeMessage = [welcomeMessage copy];
        _featureList = [featureList copy];
    }
    return self;
}

- (NSView *)createIntroductionViewWithMessage:(NSString *)message features:(NSArray<NSString *> *)features {
    NSLog(@"[GSIntroductionStep] Creating introduction view with message: %@", message);
    
    // Create container with explicit frame instead of relying solely on Auto Layout
    NSView *containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    NSLog(@"[GSIntroductionStep] Created container view with frame: %@", NSStringFromRect(containerView.frame));
    
    // Welcome message with explicit frame positioning - moved much lower
    NSTextField *messageLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 180, 360, 40)];
    messageLabel.editable = NO;
    messageLabel.selectable = NO;
    messageLabel.bordered = NO;
    messageLabel.bezeled = NO;
    messageLabel.drawsBackground = NO;
    messageLabel.backgroundColor = [NSColor clearColor];
    messageLabel.font = [NSFont systemFontOfSize:14.0];
    messageLabel.stringValue = message ?: @"Welcome to the setup assistant.";
    [containerView addSubview:messageLabel];
    NSLog(@"[GSIntroductionStep] Added message label: %@", messageLabel);
    
    CGFloat currentY = 130; // Moved down from 200 to 130
    
    // Feature list
    if (features && features.count > 0) {
        NSTextField *featuresLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, currentY, 360, 20)];
        featuresLabel.editable = NO;
        featuresLabel.selectable = NO;
        featuresLabel.bordered = NO;
        featuresLabel.bezeled = NO;
        featuresLabel.drawsBackground = NO;
        featuresLabel.backgroundColor = [NSColor clearColor];
        featuresLabel.font = [NSFont boldSystemFontOfSize:12.0];
        featuresLabel.stringValue = @"This assistant will help you:";
        [containerView addSubview:featuresLabel];
        NSLog(@"[GSIntroductionStep] Added features label");
        
        currentY -= 30;
        
        for (NSString *feature in features) {
            NSTextField *featureLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, currentY, 320, 20)];
            featureLabel.editable = NO;
            featureLabel.selectable = NO;
            featureLabel.bordered = NO;
            featureLabel.bezeled = NO;
            featureLabel.drawsBackground = NO;
            featureLabel.backgroundColor = [NSColor clearColor];
            featureLabel.font = [NSFont systemFontOfSize:12.0];
            featureLabel.stringValue = [NSString stringWithFormat:@"• %@", feature];
            [containerView addSubview:featureLabel];
            NSLog(@"[GSIntroductionStep] Added feature: %@", feature);
            
            currentY -= 25;
        }
    }
    
    NSLog(@"[GSIntroductionStep] Introduction view creation complete, container has %lu subviews", (unsigned long)containerView.subviews.count);
    return containerView;
}

@end

@implementation GSConfigurationStep

- (instancetype)initWithTitle:(NSString *)title 
                  description:(NSString *)description 
                         view:(NSView *)view {
    self = [super initWithTitle:title description:description view:view];
    if (self) {
        self.stepType = GSAssistantStepTypeConfiguration;
        _configuration = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (BOOL)validateConfiguration {
    // Override in subclasses to provide specific validation
    return YES;
}

- (BOOL)validateStep {
    return [self validateConfiguration];
}

@end

@implementation GSProgressStep

- (instancetype)initWithTitle:(NSString *)title 
                  description:(NSString *)description 
                         view:(NSView *)view {
    self = [super initWithTitle:title description:description view:view];
    if (self) {
        self.stepType = GSAssistantStepTypeProgress;
        self.canReturn = NO; // Usually can't go back during progress
        self.canProceed = NO; // Usually controlled by the progress itself
        _isIndeterminate = NO;
        if (!view) {
            self.view = [self createProgressView];
        }
    }
    return self;
}

- (NSView *)createProgressView {
    NSView *containerView = [[NSView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    
    // Current task label
    NSTextField *taskLabel = [[NSTextField alloc] init];
    taskLabel.translatesAutoresizingMaskIntoConstraints = NO;
    taskLabel.editable = NO;
    taskLabel.selectable = NO;
    taskLabel.bordered = NO;
    taskLabel.bezeled = NO;
    taskLabel.drawsBackground = NO;
    taskLabel.backgroundColor = [NSColor clearColor];
    taskLabel.font = [NSFont systemFontOfSize:14.0];
    taskLabel.stringValue = _currentTask ?: @"Processing...";
    taskLabel.alignment = NSCenterTextAlignment;
    [containerView addSubview:taskLabel];
    
    // Progress indicator
    NSProgressIndicator *progressIndicator = [[NSProgressIndicator alloc] init];
    progressIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    progressIndicator.style = NSProgressIndicatorBarStyle;
    progressIndicator.indeterminate = _isIndeterminate;
    if (_isIndeterminate) {
        [progressIndicator startAnimation:nil];
    } else {
        progressIndicator.minValue = 0.0;
        progressIndicator.maxValue = 1.0;
        progressIndicator.doubleValue = self.progress;
    }
    [containerView addSubview:progressIndicator];
    
    // Constraints
    [containerView addConstraint:[NSLayoutConstraint constraintWithItem:taskLabel
                                                             attribute:NSLayoutAttributeCenterX
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:containerView
                                                             attribute:NSLayoutAttributeCenterX
                                                            multiplier:1.0
                                                              constant:0.0]];
    
    [containerView addConstraint:[NSLayoutConstraint constraintWithItem:taskLabel
                                                             attribute:NSLayoutAttributeCenterY
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:containerView
                                                             attribute:NSLayoutAttributeCenterY
                                                            multiplier:1.0
                                                              constant:-30.0]];
    
    [containerView addConstraint:[NSLayoutConstraint constraintWithItem:progressIndicator
                                                             attribute:NSLayoutAttributeLeading
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:containerView
                                                             attribute:NSLayoutAttributeLeading
                                                            multiplier:1.0
                                                              constant:60.0]];
    
    [containerView addConstraint:[NSLayoutConstraint constraintWithItem:progressIndicator
                                                             attribute:NSLayoutAttributeTrailing
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:containerView
                                                             attribute:NSLayoutAttributeTrailing
                                                            multiplier:1.0
                                                              constant:-60.0]];
    
    [containerView addConstraint:[NSLayoutConstraint constraintWithItem:progressIndicator
                                                             attribute:NSLayoutAttributeTop
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:taskLabel
                                                             attribute:NSLayoutAttributeBottom
                                                            multiplier:1.0
                                                              constant:20.0]];
    
    return containerView;
}

- (void)updateProgress:(CGFloat)progress withTask:(NSString *)task {
    self.progress = progress;
    _currentTask = [task copy];
    
    // Update UI if the view exists
    if (self.view) {
        // Use performSelectorOnMainThread instead of dispatch_async for GNUstep compatibility
        [self performSelectorOnMainThread:@selector(updateProgressUI:) 
              withObject:@{@"progress": @(progress), @"task": task ?: @"Processing..."} 
              waitUntilDone:NO];
    }
}

- (void)updateProgressUI:(NSDictionary *)params {
    NSNumber *progressValue = params[@"progress"];
    NSString *task = params[@"task"];
    
    // Find and update the labels and progress indicators
    for (NSView *subview in self.view.subviews) {
        if ([subview isKindOfClass:[NSTextField class]]) {
            NSTextField *label = (NSTextField *)subview;
            label.stringValue = task;
        } else if ([subview isKindOfClass:[NSProgressIndicator class]]) {
            NSProgressIndicator *indicator = (NSProgressIndicator *)subview;
            if (![indicator isIndeterminate]) {
                indicator.doubleValue = [progressValue doubleValue];
            }
        }
    }
}

- (BOOL)showsProgress {
    return YES;
}

- (CGFloat)progressValue {
    return self.progress;
}

@end

@implementation GSCompletionStep

- (instancetype)initWithTitle:(NSString *)title 
                  description:(NSString *)description 
                         view:(NSView *)view {
    self = [super initWithTitle:title description:description view:view];
    if (self) {
        self.stepType = GSAssistantStepTypeCompletion;
        self.customContinueTitle = @"Finish";
        self.canReturn = NO; // Usually can't go back from completion
        self.canProceed = YES; // Completion steps can usually finish immediately
        _wasSuccessful = YES;
        if (!view) {
            self.view = [self createCompletionView];
        }
    }
    return self;
}

- (instancetype)initWithCompletionMessage:(NSString *)message success:(BOOL)success {
    NSView *completionView = [self createCompletionViewWithMessage:message success:success];
    NSString *title = success ? @"Setup Complete" : @"Setup Failed";
    self = [super initWithTitle:title description:message view:completionView];
    if (self) {
        self.stepType = GSAssistantStepTypeCompletion;
        self.customContinueTitle = success ? @"Finish" : @"Close";
        self.canReturn = NO;
        self.canProceed = YES; // Completion steps can usually finish immediately
        _completionMessage = [message copy];
        _wasSuccessful = success;
    }
    return self;
}

- (NSView *)createCompletionView {
    return [self createCompletionViewWithMessage:_completionMessage success:_wasSuccessful];
}

- (NSView *)createCompletionViewWithMessage:(NSString *)message success:(BOOL)success {
    // Create container view with explicit frame to ensure proper sizing
    NSView *containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 190)];
    containerView.translatesAutoresizingMaskIntoConstraints = YES; // Use frame-based layout
    
    // Status icon - create a text field that displays a checkmark or X
    NSTextField *statusIcon = [[NSTextField alloc] initWithFrame:NSMakeRect(198, 110, 64, 64)];
    statusIcon.editable = NO;
    statusIcon.selectable = NO;
    statusIcon.bordered = NO;
    statusIcon.bezeled = NO;
    statusIcon.drawsBackground = NO;
    statusIcon.backgroundColor = [NSColor clearColor];
    statusIcon.font = [NSFont systemFontOfSize:48.0];
    statusIcon.alignment = NSCenterTextAlignment;
    
    if (success) {
        statusIcon.stringValue = @"✓"; // Checkmark
        statusIcon.textColor = [NSColor colorWithCalibratedRed:0.0 green:0.7 blue:0.0 alpha:1.0]; // Green
    } else {
        statusIcon.stringValue = @"✗"; // X mark
        statusIcon.textColor = [NSColor colorWithCalibratedRed:0.8 green:0.0 blue:0.0 alpha:1.0]; // Red
    }
    
    [containerView addSubview:statusIcon];
    [statusIcon release]; // Release our reference since the container view retains it
    
    // Status message
    NSTextField *statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 60, 380, 40)];
    statusLabel.editable = NO;
    statusLabel.selectable = NO;
    statusLabel.bordered = NO;
    statusLabel.bezeled = NO;
    statusLabel.drawsBackground = NO;
    statusLabel.backgroundColor = [NSColor clearColor];
    statusLabel.font = [NSFont systemFontOfSize:16.0];
    statusLabel.stringValue = message ?: (success ? @"Setup completed successfully!" : @"Setup encountered an error.");
    statusLabel.alignment = NSCenterTextAlignment;
    [containerView addSubview:statusLabel];
    [statusLabel release]; // Release our reference since the container view retains it
    
    return containerView;
}

- (void)dealloc
{
    [_completionMessage release];
    [super dealloc];
}

@end
