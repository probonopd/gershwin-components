#import "GSAssistantUtilities.h"

@implementation GSAssistantUIHelper

#pragma mark - Standard UI Components

+ (NSTextField *)createTitleLabelWithText:(NSString *)text {
    NSTextField *label = [[NSTextField alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.editable = NO;
    label.selectable = NO;
    label.bordered = NO;
    label.bezeled = NO;  // Explicitly remove bezel
    label.drawsBackground = NO;  // Explicitly remove background
    label.backgroundColor = [NSColor clearColor];
    label.font = [self assistantTitleFont];
    label.stringValue = text ?: @"";
    // label.lineBreakMode = NSLineBreakByWordWrapping; // Not available in GNUstep
    // label.maximumNumberOfLines = 0; // Not available in GNUstep
    return label;
}

+ (NSTextField *)createDescriptionLabelWithText:(NSString *)text {
    NSTextField *label = [[NSTextField alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.editable = NO;
    label.selectable = NO;
    label.bordered = NO;
    label.bezeled = NO;  // Explicitly remove bezel
    label.drawsBackground = NO;  // Explicitly remove background
    label.backgroundColor = [NSColor clearColor];
    label.font = [self assistantBodyFont];
    label.textColor = [NSColor grayColor]; // Use grayColor for GNUstep compatibility
    label.stringValue = text ?: @"";
    // label.lineBreakMode = NSLineBreakByWordWrapping; // Not available in GNUstep
    // label.maximumNumberOfLines = 0; // Not available in GNUstep
    return label;
}

+ (NSTextField *)createInputFieldWithPlaceholder:(NSString *)placeholder {
    NSTextField *field = [[NSTextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholderString = placeholder ?: @"";
    field.font = [self assistantBodyFont];
    field.focusRingType = NSFocusRingTypeDefault;
    
    // Set minimum height
    [field addConstraint:[NSLayoutConstraint constraintWithItem:field
                                                      attribute:NSLayoutAttributeHeight
                                                      relatedBy:NSLayoutRelationGreaterThanOrEqual
                                                         toItem:nil
                                                      attribute:NSLayoutAttributeNotAnAttribute
                                                     multiplier:1.0
                                                       constant:24.0]];
    return field;
}

+ (NSSecureTextField *)createSecureFieldWithPlaceholder:(NSString *)placeholder {
    NSSecureTextField *field = [[NSSecureTextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholderString = placeholder ?: @"";
    field.font = [self assistantBodyFont];
    field.focusRingType = NSFocusRingTypeDefault;
    
    // Set minimum height
    [field addConstraint:[NSLayoutConstraint constraintWithItem:field
                                                      attribute:NSLayoutAttributeHeight
                                                      relatedBy:NSLayoutRelationGreaterThanOrEqual
                                                         toItem:nil
                                                      attribute:NSLayoutAttributeNotAnAttribute
                                                     multiplier:1.0
                                                       constant:24.0]];
    return field;
}

+ (NSButton *)createCheckboxWithTitle:(NSString *)title {
    NSButton *checkbox = [[NSButton alloc] init];
    checkbox.translatesAutoresizingMaskIntoConstraints = NO;
    checkbox.title = title ?: @"";
    checkbox.buttonType = NSSwitchButton;
    checkbox.font = [self assistantBodyFont];
    return checkbox;
}

+ (NSButton *)createRadioButtonWithTitle:(NSString *)title {
    NSButton *radio = [[NSButton alloc] init];
    radio.translatesAutoresizingMaskIntoConstraints = NO;
    radio.title = title ?: @"";
    radio.buttonType = NSRadioButton;
    radio.font = [self assistantBodyFont];
    return radio;
}

+ (NSPopUpButton *)createPopUpButtonWithItems:(NSArray<NSString *> *)items {
    NSPopUpButton *popup = [[NSPopUpButton alloc] init];
    popup.translatesAutoresizingMaskIntoConstraints = NO;
    popup.font = [self assistantBodyFont];
    
    if (items && items.count > 0) {
        [popup addItemsWithTitles:items];
    }
    
    // Set minimum height
    [popup addConstraint:[NSLayoutConstraint constraintWithItem:popup
                                                      attribute:NSLayoutAttributeHeight
                                                      relatedBy:NSLayoutRelationGreaterThanOrEqual
                                                         toItem:nil
                                                      attribute:NSLayoutAttributeNotAnAttribute
                                                     multiplier:1.0
                                                       constant:24.0]];
    return popup;
}

+ (NSComboBox *)createComboBoxWithItems:(NSArray<NSString *> *)items {
    NSComboBox *combo = [[NSComboBox alloc] init];
    combo.translatesAutoresizingMaskIntoConstraints = NO;
    combo.font = [self assistantBodyFont];
    combo.completes = YES;
    
    if (items && items.count > 0) {
        [combo addItemsWithObjectValues:items];
    }
    
    // Set minimum height to standard button height
    [combo addConstraint:[NSLayoutConstraint constraintWithItem:combo
                                                      attribute:NSLayoutAttributeHeight
                                                      relatedBy:NSLayoutRelationGreaterThanOrEqual
                                                         toItem:nil
                                                      attribute:NSLayoutAttributeNotAnAttribute
                                                     multiplier:1.0
                                                       constant:24.0]];
    return combo;
}

#pragma mark - Layout Helpers

+ (NSView *)createVerticalStackViewWithViews:(NSArray<NSView *> *)views spacing:(CGFloat)spacing {
    NSView *container = [[NSView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    
    NSView *previousView = nil;
    for (NSView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
        
        // Horizontal constraints
        [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                             attribute:NSLayoutAttributeLeading
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:container
                                                             attribute:NSLayoutAttributeLeading
                                                            multiplier:1.0
                                                              constant:0.0]];
        
        [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                             attribute:NSLayoutAttributeTrailing
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:container
                                                             attribute:NSLayoutAttributeTrailing
                                                            multiplier:1.0
                                                              constant:0.0]];
        
        // Vertical constraints
        if (previousView) {
            [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                                 attribute:NSLayoutAttributeTop
                                                                 relatedBy:NSLayoutRelationEqual
                                                                    toItem:previousView
                                                                 attribute:NSLayoutAttributeBottom
                                                                multiplier:1.0
                                                                  constant:spacing]];
        } else {
            [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                                 attribute:NSLayoutAttributeTop
                                                                 relatedBy:NSLayoutRelationEqual
                                                                    toItem:container
                                                                 attribute:NSLayoutAttributeTop
                                                                multiplier:1.0
                                                                  constant:0.0]];
        }
        
        previousView = view;
    }
    
    // Bottom constraint for last view
    if (previousView) {
        [container addConstraint:[NSLayoutConstraint constraintWithItem:previousView
                                                             attribute:NSLayoutAttributeBottom
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:container
                                                             attribute:NSLayoutAttributeBottom
                                                            multiplier:1.0
                                                              constant:0.0]];
    }
    
    return container;
}

+ (NSView *)createHorizontalStackViewWithViews:(NSArray<NSView *> *)views spacing:(CGFloat)spacing {
    NSView *container = [[NSView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    
    NSView *previousView = nil;
    for (NSView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
        
        // Vertical constraints
        [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                             attribute:NSLayoutAttributeTop
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:container
                                                             attribute:NSLayoutAttributeTop
                                                            multiplier:1.0
                                                              constant:0.0]];
        
        [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                             attribute:NSLayoutAttributeBottom
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:container
                                                             attribute:NSLayoutAttributeBottom
                                                            multiplier:1.0
                                                              constant:0.0]];
        
        // Horizontal constraints
        if (previousView) {
            [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                                 attribute:NSLayoutAttributeLeading
                                                                 relatedBy:NSLayoutRelationEqual
                                                                    toItem:previousView
                                                                 attribute:NSLayoutAttributeTrailing
                                                                multiplier:1.0
                                                                  constant:spacing]];
        } else {
            [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                                 attribute:NSLayoutAttributeLeading
                                                                 relatedBy:NSLayoutRelationEqual
                                                                    toItem:container
                                                                 attribute:NSLayoutAttributeLeading
                                                                multiplier:1.0
                                                                  constant:0.0]];
        }
        
        previousView = view;
    }
    
    // Trailing constraint for last view
    if (previousView) {
        [container addConstraint:[NSLayoutConstraint constraintWithItem:previousView
                                                             attribute:NSLayoutAttributeTrailing
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:container
                                                             attribute:NSLayoutAttributeTrailing
                                                            multiplier:1.0
                                                              constant:0.0]];
    }
    
    return container;
}

+ (void)addStandardConstraintsToView:(NSView *)view inContainer:(NSView *)container {
    // Create margins using the standard guidelines
    CGFloat margin = 24.0; // Standard margin from edges
    NSEdgeInsets margins;
    margins.top = 20.0; // Standard top margin
    margins.left = margin;
    margins.bottom = 20.0; // Standard bottom margin
    margins.right = margin;
    [self addStandardConstraintsToView:view inContainer:container margins:margins];
}

+ (void)addStandardConstraintsToView:(NSView *)view inContainer:(NSView *)container margins:(NSEdgeInsets)margins {
    [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                         attribute:NSLayoutAttributeLeading
                                                         relatedBy:NSLayoutRelationEqual
                                                            toItem:container
                                                         attribute:NSLayoutAttributeLeading
                                                        multiplier:1.0
                                                          constant:margins.left]];
    
    [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                         attribute:NSLayoutAttributeTrailing
                                                         relatedBy:NSLayoutRelationEqual
                                                            toItem:container
                                                         attribute:NSLayoutAttributeTrailing
                                                        multiplier:1.0
                                                          constant:-margins.right]];
    
    [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                         attribute:NSLayoutAttributeTop
                                                         relatedBy:NSLayoutRelationEqual
                                                            toItem:container
                                                         attribute:NSLayoutAttributeTop
                                                        multiplier:1.0
                                                          constant:margins.top]];
    
    [container addConstraint:[NSLayoutConstraint constraintWithItem:view
                                                         attribute:NSLayoutAttributeBottom
                                                         relatedBy:NSLayoutRelationEqual
                                                            toItem:container
                                                         attribute:NSLayoutAttributeBottom
                                                        multiplier:1.0
                                                          constant:-margins.bottom]];
}

#pragma mark - Standard Colors and Fonts

+ (NSColor *)assistantBackgroundColor {
    return [NSColor whiteColor]; // Simplified for GNUstep compatibility
}

+ (NSColor *)assistantAccentColor {
    return [NSColor blueColor]; // Simplified for GNUstep compatibility
}

+ (NSFont *)assistantTitleFont {
    return [NSFont boldSystemFontOfSize:14.0];
}

+ (NSFont *)assistantBodyFont {
    return [NSFont systemFontOfSize:13.0];
}

+ (NSFont *)assistantCaptionFont {
    return [NSFont systemFontOfSize:11.0];
}

@end

#pragma mark - Animation Manager

@implementation GSAssistantAnimationManager

+ (void)animateTransition:(GSAssistantAnimationType)animationType
                 fromView:(NSView *)fromView
                   toView:(NSView *)toView
              inContainer:(NSView *)container
                 duration:(NSTimeInterval)duration
               completion:(void(^)(void))completion {
    
    switch (animationType) {
        case GSAssistantAnimationTypeNone:
            if (fromView) {
                [fromView removeFromSuperview];
            }
            if (toView) {
                [container addSubview:toView];
            }
            if (completion) completion();
            break;
            
        case GSAssistantAnimationTypeFade:
            [self fadeTransitionFromView:fromView toView:toView inContainer:container duration:duration completion:completion];
            break;
            
        case GSAssistantAnimationTypeSlideLeft:
            [self slideTransitionFromView:fromView toView:toView inContainer:container direction:-1 duration:duration completion:completion];
            break;
            
        case GSAssistantAnimationTypeSlideRight:
            [self slideTransitionFromView:fromView toView:toView inContainer:container direction:1 duration:duration completion:completion];
            break;
            
        case GSAssistantAnimationTypeZoom:
            [self zoomTransitionFromView:fromView toView:toView inContainer:container duration:duration completion:completion];
            break;
    }
}

+ (void)fadeTransitionFromView:(NSView *)fromView 
                        toView:(NSView *)toView 
                   inContainer:(NSView *)container 
                      duration:(NSTimeInterval)duration 
                    completion:(void(^)(void))completion {
    
    // Simple fade transition without animations for GNUstep compatibility
    if (fromView) {
        [fromView removeFromSuperview];
    }
    
    if (toView) {
        toView.alphaValue = 1.0;
        [container addSubview:toView];
    }
    
    if (completion) completion();
}

+ (void)slideTransitionFromView:(NSView *)fromView 
                         toView:(NSView *)toView 
                    inContainer:(NSView *)container 
                      direction:(NSInteger)direction 
                       duration:(NSTimeInterval)duration 
                     completion:(void(^)(void))completion {
    
    // Simple slide transition without animations for GNUstep compatibility
    if (fromView) {
        [fromView removeFromSuperview];
    }
    
    if (toView) {
        [container addSubview:toView];
        toView.frame = container.bounds;
    }
    
    if (completion) completion();
}

+ (void)zoomTransitionFromView:(NSView *)fromView 
                        toView:(NSView *)toView 
                   inContainer:(NSView *)container 
                      duration:(NSTimeInterval)duration 
                    completion:(void(^)(void))completion {
    
    // Simple zoom transition without animations for GNUstep compatibility
    if (fromView) {
        [fromView removeFromSuperview];
    }
    
    if (toView) {
        toView.alphaValue = 1.0;
        [container addSubview:toView];
    }
    
    if (completion) completion();
}

+ (void)fadeInView:(NSView *)view duration:(NSTimeInterval)duration completion:(void(^)(void))completion {
    // Simple fade in without animations for GNUstep compatibility
    view.alphaValue = 1.0;
    if (completion) completion();
}

+ (void)fadeOutView:(NSView *)view duration:(NSTimeInterval)duration completion:(void(^)(void))completion {
    // Simple fade out without animations for GNUstep compatibility
    view.alphaValue = 0.0;
    if (completion) completion();
}

@end

#pragma mark - Assistant Builder

@implementation GSAssistantBuilder {
    NSString *_title;
    NSImage *_icon;
    GSAssistantLayoutStyle _layoutStyle;
    GSAssistantAnimationType _animationType;
    BOOL _showProgress;
    BOOL _allowCancel;
    NSMutableArray<id<GSAssistantStepProtocol>> *_steps;
    BOOL _includeLocalizedContent; // New property for auto-localized content
}

+ (instancetype)builder {
    NSLog(@"[GSAssistantBuilder] Creating new builder instance");
    return [[self alloc] init];
}

- (instancetype)init {
    NSLog(@"[GSAssistantBuilder] Initializing builder");
    self = [super init];
    if (self) {
        _layoutStyle = GSAssistantLayoutStyleInstaller; // Force installer layout as default and only option
        _animationType = GSAssistantAnimationTypeSlideLeft;
        _showProgress = YES;
        _allowCancel = YES;
        _steps = [[NSMutableArray alloc] init];
        _includeLocalizedContent = NO; // Default to NO
        NSLog(@"[GSAssistantBuilder] Builder initialized");
    }
    return self;
}

- (instancetype)withTitle:(NSString *)title {
    NSLog(@"[GSAssistantBuilder] Setting title: %@", title);
    _title = [title copy];
    return self;
}

- (instancetype)withIcon:(NSImage *)icon {
    NSLog(@"[GSAssistantBuilder] Setting icon: %@", icon);
    _icon = icon;
    return self;
}

- (instancetype)withAnimationType:(GSAssistantAnimationType)animationType {
    NSLog(@"[GSAssistantBuilder] Setting animation type: %ld", (long)animationType);
    _animationType = animationType;
    return self;
}

- (instancetype)withProgressBar:(BOOL)showProgress {
    NSLog(@"[GSAssistantBuilder] Setting progress bar: %@", showProgress ? @"YES" : @"NO");
    _showProgress = showProgress;
    return self;
}

- (instancetype)allowingCancel:(BOOL)allowCancel {
    NSLog(@"[GSAssistantBuilder] Setting allow cancel: %@", allowCancel ? @"YES" : @"NO");
    _allowCancel = allowCancel;
    return self;
}

- (instancetype)withAutoLocalizedContent:(BOOL)includeLocalizedContent {
    NSLog(@"[GSAssistantBuilder] Setting auto localized content: %@", includeLocalizedContent ? @"YES" : @"NO");
    _includeLocalizedContent = includeLocalizedContent;
    return self;
}

- (instancetype)addIntroductionWithMessage:(NSString *)message features:(NSArray<NSString *> *)features {
    NSLog(@"[GSAssistantBuilder] Adding introduction step with message: %@", message);
    GSIntroductionStep *step = [[GSIntroductionStep alloc] initWithWelcomeMessage:message featureList:features];
    NSLog(@"[GSAssistantBuilder] Created introduction step: %@", step);
    [_steps addObject:step];
    NSLog(@"[GSAssistantBuilder] Now have %lu steps", (unsigned long)_steps.count);
    return self;
}

- (instancetype)addStep:(id<GSAssistantStepProtocol>)step {
    NSLog(@"[GSAssistantBuilder] Adding generic step: %@", step);
    [_steps addObject:step];
    return self;
}

- (instancetype)addProgressStep:(NSString *)title description:(NSString *)description {
    GSProgressStep *step = [[GSProgressStep alloc] initWithTitle:title description:description view:nil];
    [_steps addObject:step];
    return self;
}

- (instancetype)addCompletionWithMessage:(NSString *)message success:(BOOL)success {
    GSCompletionStep *step = [[GSCompletionStep alloc] initWithCompletionMessage:message success:success];
    [_steps addObject:step];
    return self;
}

- (GSAssistantWindow *)build {
    NSLog(@"[GSAssistantBuilder] Building assistant window");
    
    // Always auto-insert localized content steps at the beginning if they exist
    NSLog(@"[GSAssistantBuilder] Auto-detecting and inserting localized content steps");
    NSMutableArray *localizedSteps = [[NSMutableArray alloc] init];
    
    // Add Welcome step if content exists
    id<GSAssistantStepProtocol> welcomeStep = [GSLocalizedContentManager createWelcomeStep];
    if (welcomeStep) {
        NSLog(@"[GSAssistantBuilder] Adding Welcome step");
        [localizedSteps addObject:welcomeStep];
    }
    
    // Add Read Me step if content exists
    id<GSAssistantStepProtocol> readMeStep = [GSLocalizedContentManager createReadMeStep];
    if (readMeStep) {
        NSLog(@"[GSAssistantBuilder] Adding Read Me step");
        [localizedSteps addObject:readMeStep];
    }
    
    // Add License step if content exists
    id<GSAssistantStepProtocol> licenseStep = [GSLocalizedContentManager createLicenseStep];
    if (licenseStep) {
        NSLog(@"[GSAssistantBuilder] Adding License step");
        [localizedSteps addObject:licenseStep];
    }
    
    // Only modify steps array if we found any localized content
    if (localizedSteps.count > 0) {
        // Insert localized steps at the beginning
        NSMutableArray *allSteps = [[NSMutableArray alloc] initWithArray:localizedSteps];
        [allSteps addObjectsFromArray:_steps];
        [localizedSteps release];
        
        // Replace the original steps array
        [_steps release];
        _steps = allSteps;
        
        NSLog(@"[GSAssistantBuilder] Total steps after adding localized content: %lu", (unsigned long)_steps.count);
    } else {
        [localizedSteps release];
        NSLog(@"[GSAssistantBuilder] No localized content found, proceeding with existing steps");
    }
    
    GSAssistantWindow *assistant = [[GSAssistantWindow alloc] initWithLayoutStyle:_layoutStyle
                                                                             title:_title 
                                                                              icon:_icon
                                                                             steps:_steps];
    assistant.animationType = _animationType;
    assistant.showsProgressBar = _showProgress;
    assistant.allowsCancel = _allowCancel;
    
    NSLog(@"[GSAssistantBuilder] Assistant window created, showing first step");
    // Show the first step immediately after creating the window
    [assistant showCurrentStep];
    
    _assistant = assistant;
    return assistant;
}

@end

#pragma mark - Assistant Templates

@implementation GSAssistantTemplates

+ (GSAssistantWindow *)createSetupAssistantWithTitle:(NSString *)title
                                                icon:(NSImage *)icon
                                            delegate:(id<GSAssistantWindowDelegate>)delegate {
    
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    GSAssistantWindow *assistant = [[[builder withTitle:title]
                                     withIcon:icon]
                                    addIntroductionWithMessage:NSLocalizedString(@"Welcome to the setup assistant. This will guide you through the initial configuration.", @"Setup assistant introduction")
                                    features:@[NSLocalizedString(@"Configure basic settings", @"Setup feature 1"), NSLocalizedString(@"Set up user preferences", @"Setup feature 2"), NSLocalizedString(@"Complete initial setup", @"Setup feature 3")]]
                                   .build;
    
    assistant.delegate = delegate;
    return assistant;
}

+ (GSAssistantWindow *)createInstallationAssistantWithTitle:(NSString *)title
                                                       icon:(NSImage *)icon
                                                   delegate:(id<GSAssistantWindowDelegate>)delegate {
    
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    GSAssistantWindow *assistant = [[[builder withTitle:title]
                                     withIcon:icon]
                                    addIntroductionWithMessage:NSLocalizedString(@"This assistant will help you install the software.", @"Installation assistant introduction")
                                    features:@[NSLocalizedString(@"Verify system requirements", @"Installation feature 1"), NSLocalizedString(@"Choose installation location", @"Installation feature 2"), NSLocalizedString(@"Install software components", @"Installation feature 3")]]
                                   .build;
    
    assistant.delegate = delegate;
    return assistant;
}

+ (GSAssistantWindow *)createConfigurationAssistantWithTitle:(NSString *)title
                                                        icon:(NSImage *)icon
                                                    delegate:(id<GSAssistantWindowDelegate>)delegate {
    
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    GSAssistantWindow *assistant = [[[builder withTitle:title]
                                     withIcon:icon]
                                    addIntroductionWithMessage:NSLocalizedString(@"Configure your settings with this assistant.", @"Configuration assistant introduction")
                                    features:@[NSLocalizedString(@"Set preferences", @"Configuration feature 1"), NSLocalizedString(@"Configure options", @"Configuration feature 2"), NSLocalizedString(@"Apply settings", @"Configuration feature 3")]]
                                   .build;
    
    assistant.delegate = delegate;
    return assistant;
}

+ (GSAssistantWindow *)createNetworkAssistantWithTitle:(NSString *)title
                                                  icon:(NSImage *)icon
                                              delegate:(id<GSAssistantWindowDelegate>)delegate {
    
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    GSAssistantWindow *assistant = [[[builder withTitle:title]
                                     withIcon:icon]
                                    addIntroductionWithMessage:NSLocalizedString(@"Set up your network connection.", @"Network assistant introduction")
                                    features:@[NSLocalizedString(@"Configure network settings", @"Network feature 1"), NSLocalizedString(@"Test connection", @"Network feature 2"), NSLocalizedString(@"Verify connectivity", @"Network feature 3")]]
                                   .build;
    
    assistant.delegate = delegate;
    return assistant;
}

@end

#pragma mark - Validator

@implementation GSAssistantValidator

+ (BOOL)validateEmail:(NSString *)email {
    if (!email || email.length == 0) return NO;
    
    NSString *emailRegex = @"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}";
    NSPredicate *emailPredicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", emailRegex];
    return [emailPredicate evaluateWithObject:email];
}

+ (BOOL)validatePassword:(NSString *)password minLength:(NSInteger)minLength {
    return password && (NSInteger)password.length >= minLength;
}

+ (BOOL)validateHostname:(NSString *)hostname {
    if (!hostname || hostname.length == 0) return NO;
    
    NSString *hostnameRegex = @"^[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?$";
    NSPredicate *hostnamePredicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", hostnameRegex];
    return [hostnamePredicate evaluateWithObject:hostname];
}

+ (BOOL)validateIPAddress:(NSString *)ipAddress {
    if (!ipAddress || ipAddress.length == 0) return NO;
    
    NSArray *components = [ipAddress componentsSeparatedByString:@"."];
    if (components.count != 4) return NO;
    
    for (NSString *component in components) {
        NSInteger value = [component integerValue];
        if (value < 0 || value > 255) return NO;
    }
    
    return YES;
}

+ (BOOL)validatePort:(NSString *)port {
    if (!port || port.length == 0) return NO;
    
    NSInteger portNumber = [port integerValue];
    return portNumber > 0 && portNumber <= 65535;
}

+ (BOOL)validateURL:(NSString *)url {
    if (!url || url.length == 0) return NO;
    
    NSURL *nsurl = [NSURL URLWithString:url];
    return nsurl != nil && nsurl.scheme != nil && nsurl.host != nil;
}

+ (BOOL)validateNotEmpty:(NSString *)text {
    return text && text.length > 0 && ![[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:@""];
}

@end

#pragma mark - GSLocalizedContentManager

@implementation GSLocalizedContentManager

static NSString *s_forcedLocale = nil;

+ (instancetype)sharedManager {
    static GSLocalizedContentManager *sharedInstance = nil;
    if (!sharedInstance) {
        sharedInstance = [[GSLocalizedContentManager alloc] init];
    }
    return sharedInstance;
}

+ (NSString *)currentLocale {
    // Check for explicit locale override via static variable (for testing)
    if (s_forcedLocale && s_forcedLocale.length > 0) {
        NSLog(@"[GSLocalizedContentManager] Using forced locale: %@", s_forcedLocale);
        return s_forcedLocale;
    }
    
    // Use NSLocale preferredLanguages - this is the standard way
    NSArray *preferredLanguages = [NSLocale preferredLanguages];
    if (preferredLanguages.count > 0) {
        NSString *language = preferredLanguages[0];
        // Extract just the language code (e.g., "en" from "en-US")
        NSArray *components = [language componentsSeparatedByString:@"-"];
        NSString *langCode = components[0];
        
        NSLog(@"[GSLocalizedContentManager] Detected locale: %@ (from preferred languages: %@)", langCode, preferredLanguages);
        return langCode;
    }
    
    NSLog(@"[GSLocalizedContentManager] Defaulting to English locale");
    return @"en"; // Default to English
}

+ (NSString *)pathForResource:(NSString *)resource locale:(NSString *)locale {
    NSBundle *bundle = [NSBundle mainBundle]; // Use main bundle (the assistant app) instead of framework bundle
    
    // First try the localized path structure
    NSString *localizedPath = [bundle pathForResource:resource 
                                               ofType:@"txt" 
                                          inDirectory:[NSString stringWithFormat:@"%@.lproj", locale]];
    
    // If not found, try the flattened structure that GNUstep might create
    if (!localizedPath) {
        localizedPath = [bundle pathForResource:resource ofType:@"txt"];
    }
    
    // Fallback to English if localized version not found
    if (!localizedPath && ![locale isEqualToString:@"en"]) {
        localizedPath = [bundle pathForResource:resource 
                                         ofType:@"txt" 
                                    inDirectory:@"en.lproj"];
        
        // Try flattened structure for fallback too
        if (!localizedPath) {
            localizedPath = [bundle pathForResource:resource ofType:@"txt"];
        }
    }
    
    return localizedPath;
}

+ (NSString *)contentForResource:(NSString *)resource locale:(NSString *)locale {
    NSString *path = [self pathForResource:resource locale:locale];
    if (!path) return nil;
    
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:path 
                                                   encoding:NSUTF8StringEncoding 
                                                      error:&error];
    
    if (error) {
        NSLog(@"[GSLocalizedContentManager] Error reading %@.txt for locale %@: %@", resource, locale, error.localizedDescription);
        return nil;
    }
    
    return content;
}

#pragma mark - Content Availability Checks

+ (BOOL)hasWelcomeContent {
    return [self pathForResource:@"Welcome" locale:[self currentLocale]] != nil;
}

+ (BOOL)hasReadMeContent {
    return [self pathForResource:@"ReadMe" locale:[self currentLocale]] != nil;
}

+ (BOOL)hasLicenseContent {
    return [self pathForResource:@"License" locale:[self currentLocale]] != nil;
}

#pragma mark - Content Retrieval

+ (NSString *)welcomeContent {
    return [self welcomeContentForLocale:[self currentLocale]];
}

+ (NSString *)readMeContent {
    return [self readMeContentForLocale:[self currentLocale]];
}

+ (NSString *)licenseContent {
    return [self licenseContentForLocale:[self currentLocale]];
}

+ (NSString *)welcomeContentForLocale:(NSString *)locale {
    return [self contentForResource:@"Welcome" locale:locale];
}

+ (NSString *)readMeContentForLocale:(NSString *)locale {
    return [self contentForResource:@"ReadMe" locale:locale];
}

+ (NSString *)licenseContentForLocale:(NSString *)locale {
    return [self contentForResource:@"License" locale:locale];
}

#pragma mark - Step Creation

+ (id<GSAssistantStepProtocol>)createWelcomeStep {
    NSString *content = [self welcomeContent];
    if (!content) return nil;
    
    return [[GSWelcomeStep alloc] initWithContent:content];
}

+ (id<GSAssistantStepProtocol>)createReadMeStep {
    NSString *content = [self readMeContent];
    if (!content) return nil;
    
    return [[GSReadMeStep alloc] initWithContent:content];
}

+ (id<GSAssistantStepProtocol>)createLicenseStep {
    NSString *content = [self licenseContent];
    if (!content) return nil;
    
    return [[GSLicenseStep alloc] initWithContent:content requiresAcceptance:YES];
}

#pragma mark - Unified Localization

+ (void)forceLocale:(NSString *)locale {
    NSLog(@"[GSLocalizedContentManager] Forcing locale to: %@", locale);
    s_forcedLocale = [locale copy];
}

+ (void)clearForcedLocale {
    NSLog(@"[GSLocalizedContentManager] Clearing forced locale");
    s_forcedLocale = nil;
}

@end
