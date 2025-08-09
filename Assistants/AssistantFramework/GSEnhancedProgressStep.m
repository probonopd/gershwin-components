//
// GSEnhancedProgressStep.m
// GSAssistantFramework - Enhanced Progress Step
//

#import "GSEnhancedProgressStep.h"

@implementation GSEnhancedProgressStep

@synthesize stepTitle = _stepTitle;
@synthesize stepDescription = _stepDescription;
@synthesize delegate = _delegate;
@synthesize currentPhase = _currentPhase;
@synthesize progress = _progress;
@synthesize statusMessage = _statusMessage;
@synthesize progressMessage = _progressMessage;
@synthesize allowsCancellation = _allowsCancellation;
@synthesize isCompleted = _isCompleted;
@synthesize wasSuccessful = _wasSuccessful;

- (id)initWithTitle:(NSString *)title description:(NSString *)description
{
    if (self = [super init]) {
        NSLog(@"GSEnhancedProgressStep: init");
        _stepTitle = [title retain];
        _stepDescription = [description retain];
        _phases = [[NSMutableArray alloc] init];
        _progress = 0.0;
        _currentPhase = GSProgressPhaseInitialization;
        _allowsCancellation = YES;
        _isCompleted = NO;
        _wasSuccessful = NO;
        _statusMessage = [@"Initializing..." retain];
        _progressMessage = [@"" retain];
        
        // Add default phases
        [self addPhase:GSProgressPhaseInitialization withTitle:@"Initializing"];
        [self addPhase:GSProgressPhaseDownloading withTitle:@"Downloading"];
        [self addPhase:GSProgressPhaseProcessing withTitle:@"Processing"];
        [self addPhase:GSProgressPhaseInstalling withTitle:@"Installing"];
        [self addPhase:GSProgressPhaseCompleting withTitle:@"Completing"];
        
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"GSEnhancedProgressStep: dealloc");
    [_stepView release];
    [_stepTitle release];
    [_stepDescription release];
    [_statusMessage release];
    [_progressMessage release];
    [_phases release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"GSEnhancedProgressStep: setupView");
    
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 360)];
    
    // Icon view
    _iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(190, 250, 100, 80)];
    [_iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
    [_stepView addSubview:_iconView];
    [_iconView release];
    
    // Phase label
    _phaseLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 210, 440, 25)];
    [_phaseLabel setStringValue:[self titleForPhase:_currentPhase]];
    [_phaseLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [_phaseLabel setAlignment:NSCenterTextAlignment];
    [_phaseLabel setBezeled:NO];
    [_phaseLabel setDrawsBackground:NO];
    [_phaseLabel setEditable:NO];
    [_phaseLabel setSelectable:NO];
    [_stepView addSubview:_phaseLabel];
    [_phaseLabel release];
    
    // Status label
    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 180, 440, 25)];
    [_statusLabel setStringValue:_statusMessage];
    [_statusLabel setFont:[NSFont systemFontOfSize:12]];
    [_statusLabel setAlignment:NSCenterTextAlignment];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_stepView addSubview:_statusLabel];
    [_statusLabel release];
    
    // Progress bar
    _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(60, 140, 360, 20)];
    [_progressBar setStyle:NSProgressIndicatorBarStyle];
    [_progressBar setMinValue:0.0];
    [_progressBar setMaxValue:100.0];
    [_progressBar setDoubleValue:_progress * 100.0];
    [_stepView addSubview:_progressBar];
    [_progressBar release];
    
    // Progress message label
    _progressLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 110, 440, 20)];
    [_progressLabel setStringValue:_progressMessage];
    [_progressLabel setAlignment:NSCenterTextAlignment];
    [_progressLabel setBezeled:NO];
    [_progressLabel setDrawsBackground:NO];
    [_progressLabel setEditable:NO];
    [_progressLabel setSelectable:NO];
    [_progressLabel setFont:[NSFont systemFontOfSize:11]];
    [_stepView addSubview:_progressLabel];
    [_progressLabel release];
    
    // Cancel button
    _cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(190, 50, 100, 32)];
    [_cancelButton setTitle:@"Cancel"];
    [_cancelButton setTarget:self];
    [_cancelButton setAction:@selector(cancelPressed:)];
    [_cancelButton setHidden:!_allowsCancellation];
    [_stepView addSubview:_cancelButton];
    [_cancelButton release];
}

- (void)addPhase:(GSProgressPhase)phase withTitle:(NSString *)title
{
    NSDictionary *phaseInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSNumber numberWithInteger:phase], @"phase",
                              title, @"title",
                              nil];
    [_phases addObject:phaseInfo];
}

- (NSString *)titleForPhase:(GSProgressPhase)phase
{
    for (NSDictionary *phaseInfo in _phases) {
        NSNumber *phaseNumber = [phaseInfo objectForKey:@"phase"];
        if ([phaseNumber integerValue] == phase) {
            return [phaseInfo objectForKey:@"title"];
        }
    }
    
    // Fallback titles
    switch (phase) {
        case GSProgressPhaseInitialization: return @"Initializing";
        case GSProgressPhaseDownloading: return @"Downloading";
        case GSProgressPhaseProcessing: return @"Processing";
        case GSProgressPhaseInstalling: return @"Installing";
        case GSProgressPhaseCompleting: return @"Completing";
        default: return @"Working";
    }
}

- (void)setPhase:(GSProgressPhase)phase withMessage:(NSString *)message
{
    NSLog(@"GSEnhancedProgressStep: setPhase: %ld withMessage: %@", (long)phase, message);
    
    _currentPhase = phase;
    
    [_statusMessage release];
    _statusMessage = [message retain];
    
    // Update UI on main thread
    [self performSelectorOnMainThread:@selector(updateUI) withObject:nil waitUntilDone:NO];
}

- (void)updateProgress:(float)progress withMessage:(NSString *)message
{
    NSLog(@"GSEnhancedProgressStep: updateProgress: %.2f withMessage: %@", progress, message);
    
    _progress = progress;
    
    if (message) {
        [_progressMessage release];
        _progressMessage = [message retain];
    }
    
    // Update UI on main thread
    [self performSelectorOnMainThread:@selector(updateUI) withObject:nil waitUntilDone:NO];
}

- (void)completeWithSuccess:(BOOL)success error:(NSString *)error
{
    NSLog(@"GSEnhancedProgressStep: completeWithSuccess: %d error: %@", success, error);
    
    _isCompleted = YES;
    _wasSuccessful = success;
    
    if (success) {
        [self setPhase:GSProgressPhaseCompleting withMessage:@"Completed successfully!"];
        [self updateProgress:1.0 withMessage:@"Done"];
        
        // Update icon to success
        NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"check" ofType:@"png"];
        if (iconPath) {
            NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
            if (icon) {
                [_iconView setImage:icon];
                [icon release];
            }
        }
    } else {
        [_statusMessage release];
        _statusMessage = [@"Failed" retain];
        
        [_progressMessage release];
        _progressMessage = [error ? error : @"Unknown error occurred" retain];
        
        // Update icon to error
        NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"cross" ofType:@"png"];
        if (iconPath) {
            NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
            if (icon) {
                [_iconView setImage:icon];
                [icon release];
            }
        }
    }
    
    // Hide cancel button when completed
    [_cancelButton setHidden:YES];
    
    // Update UI
    [self updateUI];
    
    // Notify delegate
    if (_delegate && [_delegate respondsToSelector:@selector(progressStepDidComplete:error:)]) {
        [_delegate progressStepDidComplete:success error:error];
    }
}

- (void)updateUI
{
    [_phaseLabel setStringValue:[self titleForPhase:_currentPhase]];
    [_statusLabel setStringValue:_statusMessage];
    [_progressLabel setStringValue:_progressMessage];
    [_progressBar setDoubleValue:_progress * 100.0];
    [_cancelButton setHidden:!_allowsCancellation || _isCompleted];
}

- (void)cancelPressed:(id)sender
{
    NSLog(@"GSEnhancedProgressStep: cancelPressed");
    
    if (_delegate && [_delegate respondsToSelector:@selector(progressStepDidCancel)]) {
        [_delegate progressStepDidCancel];
    }
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return _stepTitle;
}

- (NSString *)stepDescription  
{
    return _stepDescription;
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    return _isCompleted && _wasSuccessful;
}

- (void)stepWillAppear
{
    NSLog(@"GSEnhancedProgressStep: stepWillAppear");
}

- (void)stepDidAppear
{
    NSLog(@"GSEnhancedProgressStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"GSEnhancedProgressStep: stepWillDisappear");
}

@end
