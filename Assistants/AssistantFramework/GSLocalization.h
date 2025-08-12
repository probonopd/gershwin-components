//
// GSLocalization.h
// GSAssistantFramework
//
// Localization support for the GSAssistantFramework
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * GSLocalization provides localized strings for the GSAssistantFramework.
 * It automatically detects the system language and falls back to English if needed.
 */
@interface GSLocalization : NSObject

/**
 * Get a localized string for the given key.
 * @param key The localization key
 * @return The localized string, or the key itself if no translation is found
 */
+ (NSString *)localizedString:(NSString *)key;

/**
 * Get a localized string with fallback.
 * @param key The localization key
 * @param fallback The fallback string if no translation is found
 * @return The localized string, or the fallback if no translation is found
 */
+ (NSString *)localizedString:(NSString *)key fallback:(NSString *)fallback;

/**
 * Get the current system locale (language code only, e.g., "en", "de")
 */
+ (NSString *)currentLanguage;

@end

// Convenience macro for localization
#define GSLocalizedString(key) [GSLocalization localizedString:key]
#define GSLocalizedStringWithFallback(key, fallback) [GSLocalization localizedString:key fallback:fallback]

NS_ASSUME_NONNULL_END
