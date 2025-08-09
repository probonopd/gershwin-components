//
// GSEnhancedProgressStep.h
// GSAssistantFramework - Enhanced Progress Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "GSAssistantFramework.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GSProgressPhase) {
    GSProgressPhaseInitialization,
    GSProgressPhaseDownloading,
    GSProgressPhaseProcessing,
    GSProgressPhaseInstalling,
    GSProgressPhaseCompleting
};

@protocol GSEnhancedProgressDelegate <NSObject>
@optional
- (void)progressStepDidCancel;
- (void)progressStepDidComplete:(BOOL)success error:(nullable NSString *)error;
@end

@interface GSEnhancedProgressStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSProgressIndicator *_progressBar;
    NSTextField *_statusLabel;
    NSTextField *_progressLabel;
    NSTextField *_phaseLabel;
    NSButton *_cancelButton;
    NSImageView *_iconView;
    
    NSString *_stepTitle;
    NSString *_stepDescription;
    id<GSEnhancedProgressDelegate> _delegate;
    
    GSProgressPhase _currentPhase;
    float _progress;
    NSString *_statusMessage;
    NSString *_progressMessage;
    NSMutableArray *_phases;
    BOOL _allowsCancellation;
    BOOL _isCompleted;
    BOOL _wasSuccessful;
}

@property (nonatomic, retain) NSString *stepTitle;
@property (nonatomic, retain) NSString *stepDescription;
@property (nonatomic, assign) id<GSEnhancedProgressDelegate> delegate;
@property (nonatomic, assign) GSProgressPhase currentPhase;
@property (nonatomic, assign) float progress;
@property (nonatomic, retain) NSString *statusMessage;
@property (nonatomic, retain) NSString *progressMessage;
@property (nonatomic, assign) BOOL allowsCancellation;
@property (nonatomic, readonly) BOOL isCompleted;
@property (nonatomic, readonly) BOOL wasSuccessful;

- (id)initWithTitle:(NSString *)title description:(NSString *)description;

// Progress management
- (void)setPhase:(GSProgressPhase)phase withMessage:(NSString *)message;
- (void)updateProgress:(float)progress withMessage:(nullable NSString *)message;
- (void)completeWithSuccess:(BOOL)success error:(nullable NSString *)error;

// Phase management
- (void)addPhase:(GSProgressPhase)phase withTitle:(NSString *)title;
- (NSString *)titleForPhase:(GSProgressPhase)phase;

@end

NS_ASSUME_NONNULL_END
