#import "GSAssistantFramework.h"

// Layout constants matching the installer design
static const CGFloat GSInstallerWindowWidth = 620.0;
static const CGFloat GSInstallerWindowHeight = 460.0;
static const CGFloat GSInstallerSidebarWidth = 170.0;
static const CGFloat GSInstallerButtonAreaHeight = 60.0;
static const CGFloat GSInstallerButtonHeight = 24.0;
static const CGFloat GSInstallerButtonWidth = 80.0;

/**
 * Installer Assistant Window that matches installer design
 */
@interface GSModernInstallerWindow : NSWindowController

@property (nonatomic, strong) NSString *installerTitle;
@property (nonatomic, strong) NSImage *installerIcon;
@property (nonatomic, strong) NSMutableArray<id<GSAssistantStepProtocol>> *steps;
@property (nonatomic, assign) NSInteger currentStepIndex;

// Main layout views
@property (nonatomic, strong) NSView *mainContainerView;
@property (nonatomic, strong) NSView *sidebarView;
@property (nonatomic, strong) NSView *contentAreaView;
@property (nonatomic, strong) NSView *buttonAreaView;

// Sidebar elements
@property (nonatomic, strong) NSMutableArray<NSView *> *stepIndicatorViews;
@property (nonatomic, strong) NSImageView *backgroundLogoView;

// Content area elements
@property (nonatomic, strong) NSTextField *stepTitleField;
@property (nonatomic, strong) NSView *currentStepContentView;

// Button area elements
@property (nonatomic, strong) NSButton *optionsButton;
@property (nonatomic, strong) NSButton *goBackButton;
@property (nonatomic, strong) NSButton *continueButton;

- (instancetype)initWithTitle:(NSString *)title 
                         icon:(NSImage *)icon
                        steps:(NSArray<id<GSAssistantStepProtocol>> *)steps;

- (void)goToStep:(NSInteger)stepIndex;
- (void)nextStep;
- (void)previousStep;

@end

/**
 * Base class for installer steps
 */
@interface GSModernInstallerStep : NSObject <GSAssistantStepProtocol>

@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) NSString *stepDescription;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, assign) BOOL canProceed;

- (instancetype)initWithTitle:(NSString *)title description:(NSString *)description;
- (NSView *)createContentView; // Override in subclasses

@end

/**
 * Introduction step with welcome message and icon array
 */
@interface GSModernIntroductionStep : GSModernInstallerStep

@property (nonatomic, strong) NSArray<NSImage *> *applicationIcons;
@property (nonatomic, strong) NSString *welcomeMessage;

- (instancetype)initWithWelcomeMessage:(NSString *)message icons:(NSArray<NSImage *> *)icons;

@end

/**
 * Destination selection step with disk selection
 */
@interface GSModernDestinationStep : GSModernInstallerStep

@property (nonatomic, strong) NSArray *availableDisks;
@property (nonatomic, strong) NSDictionary *selectedDisk;

@end

/**
 * Installation progress step with progress bar
 */
@interface GSModernInstallationProgressStep : GSModernInstallerStep

@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *timeRemainingLabel;
@property (nonatomic, assign) double progressValue;

- (void)updateProgress:(double)progress status:(NSString *)status timeRemaining:(NSString *)timeString;

@end

/**
 * Completion step with restart option
 */
@interface GSModernCompletionStep : GSModernInstallerStep

@property (nonatomic, strong) NSTextField *completionMessageLabel;
@property (nonatomic, strong) NSTextField *countdownLabel;
@property (nonatomic, assign) NSInteger countdownSeconds;

- (void)startRestartCountdown:(NSInteger)seconds;

@end
