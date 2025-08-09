#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations
@class GSAssistantWindow;
@class GSAssistantStep;
@protocol GSAssistantWindowDelegate;

// Assistant Step Types
typedef NS_ENUM(NSInteger, GSAssistantStepType) {
    GSAssistantStepTypeIntroduction,
    GSAssistantStepTypeConfiguration,
    GSAssistantStepTypeProgress,
    GSAssistantStepTypeConfirmation,
    GSAssistantStepTypeCompletion
};

// Navigation Button Types
typedef NS_ENUM(NSInteger, GSAssistantButtonType) {
    GSAssistantButtonTypeBack,
    GSAssistantButtonTypeContinue,
    GSAssistantButtonTypeFinish,
    GSAssistantButtonTypeCancel,
    GSAssistantButtonTypeCustom
};

// Animation Types
typedef NS_ENUM(NSInteger, GSAssistantAnimationType) {
    GSAssistantAnimationTypeNone,
    GSAssistantAnimationTypeSlideLeft,
    GSAssistantAnimationTypeSlideRight,
    GSAssistantAnimationTypeFade,
    GSAssistantAnimationTypeZoom
};

// Assistant Layout Style Types
typedef NS_ENUM(NSInteger, GSAssistantLayoutStyle) {
    GSAssistantLayoutStyleDefault,     // Original assistant layout
    GSAssistantLayoutStyleInstaller,   // Installer-style layout (620x460, sidebar with steps)
    GSAssistantLayoutStyleWizard       // Wizard-style layout (for future use)
};

// Layout constants
extern const CGFloat GSAssistantDefaultWindowWidth;
extern const CGFloat GSAssistantDefaultWindowHeight;
extern const CGFloat GSAssistantInstallerWindowWidth;
extern const CGFloat GSAssistantInstallerWindowHeight;
extern const CGFloat GSAssistantInstallerSidebarWidth;
extern const CGFloat GSAssistantInstallerButtonAreaHeight;

/**
 * Protocol for assistant step implementations
 */
@protocol GSAssistantStepProtocol <NSObject>

@required
- (NSString *)stepTitle;
- (NSString *)stepDescription;
- (NSView *)stepView;
- (BOOL)canContinue;

@optional
- (void)stepWillAppear;
- (void)stepDidAppear;
- (void)stepWillDisappear;
- (void)stepDidDisappear;
- (BOOL)validateStep;
- (void)resetStep;
- (NSString *)continueButtonTitle;
- (NSString *)backButtonTitle;
- (BOOL)canGoBack;
- (BOOL)showsProgress;
- (CGFloat)progressValue; // 0.0 to 1.0

@end

/**
 * Protocol for assistant window delegate
 */
@protocol GSAssistantWindowDelegate <NSObject>

@optional
- (void)assistantWindowWillClose:(GSAssistantWindow *)window;
- (void)assistantWindowDidClose:(GSAssistantWindow *)window;
- (void)assistantWindowWillFinish:(GSAssistantWindow *)window;
- (void)assistantWindowDidFinish:(GSAssistantWindow *)window;
- (void)assistantWindowDidCancel:(GSAssistantWindow *)window;
- (void)assistantWindow:(GSAssistantWindow *)window willShowStep:(id<GSAssistantStepProtocol>)step;
- (void)assistantWindow:(GSAssistantWindow *)window didShowStep:(id<GSAssistantStepProtocol>)step;
- (void)assistantWindow:(GSAssistantWindow *)window didFinishWithResult:(BOOL)success;
- (BOOL)assistantWindow:(GSAssistantWindow *)window shouldCancelWithConfirmation:(BOOL)showConfirmation;

@end

/**
 * Main Assistant Window Class
 */
@interface GSAssistantWindow : NSWindowController

@property (nonatomic, assign, nullable) id<GSAssistantWindowDelegate> delegate;
@property (nonatomic, strong, readonly) NSMutableArray<id<GSAssistantStepProtocol>> *steps;
@property (nonatomic, assign, readonly) NSInteger currentStepIndex;
@property (nonatomic, assign) GSAssistantAnimationType animationType;
@property (nonatomic, assign) NSTimeInterval animationDuration;
@property (nonatomic, strong, nullable) NSString *assistantTitle;
@property (nonatomic, strong, nullable) NSImage *assistantIcon;
@property (nonatomic, assign) BOOL showsProgressBar;
@property (nonatomic, assign) BOOL allowsCancel;
@property (nonatomic, assign) GSAssistantLayoutStyle layoutStyle;
@property (nonatomic, assign) BOOL showsSidebar;           // For installer layout
@property (nonatomic, assign) BOOL showsStepIndicators;    // Show step progress in sidebar

// Initialization
- (instancetype)initWithSteps:(NSArray<id<GSAssistantStepProtocol>> *)steps;
- (instancetype)initWithAssistantTitle:(nullable NSString *)title 
                                  icon:(nullable NSImage *)icon
                                 steps:(NSArray<id<GSAssistantStepProtocol>> *)steps;
- (instancetype)initWithLayoutStyle:(GSAssistantLayoutStyle)layoutStyle
                               title:(nullable NSString *)title 
                                icon:(nullable NSImage *)icon
                               steps:(NSArray<id<GSAssistantStepProtocol>> *)steps;

// Step Management
- (void)addStep:(id<GSAssistantStepProtocol>)step;
- (void)insertStep:(id<GSAssistantStepProtocol>)step atIndex:(NSInteger)index;
- (void)removeStepAtIndex:(NSInteger)index;
- (void)removeStep:(id<GSAssistantStepProtocol>)step;
- (id<GSAssistantStepProtocol>)currentStep;

// Navigation
- (void)showCurrentStep;
- (void)goToNextStep;
- (void)goToPreviousStep;
- (void)goToStepAtIndex:(NSInteger)index;
- (void)finishAssistant;
- (void)cancelAssistant;

// UI Updates
- (void)updateNavigationButtons;
- (void)updateProgressBar;
- (void)updateStepInfo;

// Error and Success Pages
- (void)showErrorPageWithMessage:(NSString *)message;
- (void)showErrorPageWithTitle:(NSString *)title message:(NSString *)message;
- (void)showSuccessPageWithTitle:(NSString *)title message:(NSString *)message;

@end

/**
 * Base Assistant Step Implementation
 */
@interface GSAssistantStep : NSObject <GSAssistantStepProtocol>

@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) NSString *stepDescription;
@property (nonatomic, strong, nullable) NSView *view;
@property (nonatomic, assign) GSAssistantStepType stepType;
@property (nonatomic, assign) BOOL canProceed;
@property (nonatomic, assign) BOOL canReturn;
@property (nonatomic, strong, nullable) NSString *customContinueTitle;
@property (nonatomic, strong, nullable) NSString *customBackTitle;
@property (nonatomic, assign) CGFloat progress; // 0.0 to 1.0

- (instancetype)initWithTitle:(NSString *)title 
                  description:(NSString *)description 
                         view:(nullable NSView *)view;

@end

/**
 * Specialized step types
 */

// Introduction Step
@interface GSIntroductionStep : GSAssistantStep
@property (nonatomic, strong, nullable) NSString *welcomeMessage;
@property (nonatomic, strong, nullable) NSArray<NSString *> *featureList;
- (instancetype)initWithWelcomeMessage:(NSString *)welcomeMessage featureList:(NSArray<NSString *> *)featureList;
@end

// Configuration Step
@interface GSConfigurationStep : GSAssistantStep
@property (nonatomic, strong, nullable) NSDictionary *configuration;
- (BOOL)validateConfiguration;
@end

// Progress Step
@interface GSProgressStep : GSAssistantStep
@property (nonatomic, strong, nullable) NSString *currentTask;
@property (nonatomic, assign) BOOL isIndeterminate;
- (void)updateProgress:(CGFloat)progress withTask:(nullable NSString *)task;
- (void)updateProgressUI:(NSDictionary *)params;
@end

// Completion Step
@interface GSCompletionStep : GSAssistantStep
@property (nonatomic, strong, nullable) NSString *completionMessage;
@property (nonatomic, assign) BOOL wasSuccessful;
- (instancetype)initWithCompletionMessage:(NSString *)message success:(BOOL)success;
@end

// Test class with NSWindowController inheritance

NS_ASSUME_NONNULL_END

// Import utility classes
#import "GSAssistantUtilities.h"
#import "GSNetworkUtilities.h"
#import "GSDiskUtilities.h"
#import "GSSelectionStep.h"
#import "GSEnhancedProgressStep.h"
