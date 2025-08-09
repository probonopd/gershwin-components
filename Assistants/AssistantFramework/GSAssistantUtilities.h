#import "GSAssistantFramework.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Utility class for creating common UI elements with standard macOS appearance
 */
@interface GSAssistantUIHelper : NSObject

// Standard UI Components
+ (NSTextField *)createTitleLabelWithText:(NSString *)text;
+ (NSTextField *)createDescriptionLabelWithText:(NSString *)text;
+ (NSTextField *)createInputFieldWithPlaceholder:(nullable NSString *)placeholder;
+ (NSSecureTextField *)createSecureFieldWithPlaceholder:(nullable NSString *)placeholder;
+ (NSButton *)createCheckboxWithTitle:(NSString *)title;
+ (NSButton *)createRadioButtonWithTitle:(NSString *)title;
+ (NSPopUpButton *)createPopUpButtonWithItems:(NSArray<NSString *> *)items;
+ (NSComboBox *)createComboBoxWithItems:(NSArray<NSString *> *)items;

// Layout Helpers
+ (NSView *)createVerticalStackViewWithViews:(NSArray<NSView *> *)views spacing:(CGFloat)spacing;
+ (NSView *)createHorizontalStackViewWithViews:(NSArray<NSView *> *)views spacing:(CGFloat)spacing;
+ (void)addStandardConstraintsToView:(NSView *)view inContainer:(NSView *)container;
+ (void)addStandardConstraintsToView:(NSView *)view inContainer:(NSView *)container margins:(NSEdgeInsets)margins;

// Standard Colors and Fonts
+ (NSColor *)assistantBackgroundColor;
+ (NSColor *)assistantAccentColor;
+ (NSFont *)assistantTitleFont;
+ (NSFont *)assistantBodyFont;
+ (NSFont *)assistantCaptionFont;

@end

/**
 * Manager for handling assistant animations
 */
@interface GSAssistantAnimationManager : NSObject

+ (void)animateTransition:(GSAssistantAnimationType)animationType
                 fromView:(nullable NSView *)fromView
                   toView:(NSView *)toView
              inContainer:(NSView *)container
                 duration:(NSTimeInterval)duration
               completion:(nullable void(^)(void))completion;

+ (void)fadeInView:(NSView *)view duration:(NSTimeInterval)duration completion:(nullable void(^)(void))completion;
+ (void)fadeOutView:(NSView *)view duration:(NSTimeInterval)duration completion:(nullable void(^)(void))completion;

@end

/**
 * Assistant Builder - Fluent interface for creating assistants
 */
@interface GSAssistantBuilder : NSObject

@property (nonatomic, strong, readonly) GSAssistantWindow *assistant;

+ (instancetype)builder;

- (instancetype)withTitle:(NSString *)title;
- (instancetype)withIcon:(NSImage *)icon;
- (instancetype)withLayoutStyle:(GSAssistantLayoutStyle)layoutStyle;
- (instancetype)withAnimationType:(GSAssistantAnimationType)animationType;
- (instancetype)withProgressBar:(BOOL)showProgress;
- (instancetype)allowingCancel:(BOOL)allowCancel;

- (instancetype)addIntroductionWithMessage:(NSString *)message features:(nullable NSArray<NSString *> *)features;
- (instancetype)addStep:(id<GSAssistantStepProtocol>)step;
- (instancetype)addProgressStep:(NSString *)title description:(NSString *)description;
- (instancetype)addCompletionWithMessage:(NSString *)message success:(BOOL)success;

- (GSAssistantWindow *)build;

@end

/**
 * Pre-built assistant templates
 */
@interface GSAssistantTemplates : NSObject

// Common Assistant Types
+ (GSAssistantWindow *)createSetupAssistantWithTitle:(NSString *)title
                                                icon:(nullable NSImage *)icon
                                            delegate:(nullable id<GSAssistantWindowDelegate>)delegate;

+ (GSAssistantWindow *)createInstallationAssistantWithTitle:(NSString *)title
                                                       icon:(nullable NSImage *)icon
                                                   delegate:(nullable id<GSAssistantWindowDelegate>)delegate;

+ (GSAssistantWindow *)createConfigurationAssistantWithTitle:(NSString *)title
                                                        icon:(nullable NSImage *)icon
                                                    delegate:(nullable id<GSAssistantWindowDelegate>)delegate;

+ (GSAssistantWindow *)createNetworkAssistantWithTitle:(NSString *)title
                                                  icon:(nullable NSImage *)icon
                                              delegate:(nullable id<GSAssistantWindowDelegate>)delegate;

@end

/**
 * Common validation utilities
 */
@interface GSAssistantValidator : NSObject

+ (BOOL)validateEmail:(NSString *)email;
+ (BOOL)validatePassword:(NSString *)password minLength:(NSInteger)minLength;
+ (BOOL)validateHostname:(NSString *)hostname;
+ (BOOL)validateIPAddress:(NSString *)ipAddress;
+ (BOOL)validatePort:(NSString *)port;
+ (BOOL)validateURL:(NSString *)url;
+ (BOOL)validateNotEmpty:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
