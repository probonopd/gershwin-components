//
// GSLocalization.m
// GSAssistantFramework
//
// Localization support for the GSAssistantFramework
//

#import "GSLocalization.h"

@implementation GSLocalization

+ (NSString *)currentLanguage {
    NSArray *preferredLanguages = [NSLocale preferredLanguages];
    if (preferredLanguages.count > 0) {
        NSString *language = preferredLanguages[0];
        // Extract just the language code (e.g., "en" from "en-US")
        NSArray *components = [language componentsSeparatedByString:@"-"];
        return components[0];
    }
    return @"en"; // Default to English
}

+ (NSDictionary *)germanStrings {
    static NSDictionary *germanTranslations = nil;
    if (!germanTranslations) {
        germanTranslations = @{
            // General UI
            @"Setup Assistant": @"Einrichtungsassistent",
            @"Cancel": @"Abbrechen",
            @"Go Back": @"Zurück",
            @"Continue": @"Weiter",
            @"Finish": @"Beenden",
            @"Error": @"Fehler",
            @"Setup Complete": @"Einrichtung abgeschlossen",
            
            // Step titles and descriptions
            @"Welcome": @"Willkommen",
            @"Read Me": @"Lies mich",
            @"Software License Agreement": @"Software-Lizenzvereinbarung",
            @"Welcome to the assistant": @"Willkommen beim Assistenten",
            @"Important information": @"Wichtige Informationen",
            @"Please read the license agreement": @"Bitte lesen Sie die Lizenzvereinbarung",
            
            // Generic messages
            @"Processing...": @"Verarbeitung...",
            @"Setup completed successfully!": @"Einrichtung erfolgreich abgeschlossen!",
            @"Setup encountered an error.": @"Bei der Einrichtung ist ein Fehler aufgetreten.",
            @"An error occurred during the process.": @"Während des Vorgangs ist ein Fehler aufgetreten.",
            @"The process completed successfully.": @"Der Vorgang wurde erfolgreich abgeschlossen.",
            
            // Introduction step
            @"Welcome to the setup assistant.": @"Willkommen beim Einrichtungsassistenten.",
            @"This assistant will help you:": @"Dieser Assistent hilft Ihnen dabei:",
            @"Get Started": @"Loslegen",
            
            // License step
            @"I agree to the terms of this license agreement": @"Ich stimme den Bedingungen dieser Lizenzvereinbarung zu",
            
            // Template messages
            @"Welcome to the setup assistant. This will guide you through the initial configuration.": @"Willkommen beim Einrichtungsassistenten. Dieser führt Sie durch die Erstkonfiguration.",
            @"Configure basic settings": @"Grundeinstellungen konfigurieren",
            @"Set up user preferences": @"Benutzereinstellungen festlegen", 
            @"Complete initial setup": @"Ersteinrichtung abschließen",
            @"This assistant will help you install the software.": @"Dieser Assistent hilft Ihnen bei der Installation der Software.",
            @"Verify system requirements": @"Systemanforderungen überprüfen",
            @"Choose installation location": @"Installationsort wählen",
            @"Install software components": @"Softwarekomponenten installieren",
            @"Configure your settings with this assistant.": @"Konfigurieren Sie Ihre Einstellungen mit diesem Assistenten.",
            @"Set preferences": @"Einstellungen festlegen",
            @"Configure options": @"Optionen konfigurieren",
            @"Apply settings": @"Einstellungen anwenden",
            @"Set up your network connection.": @"Richten Sie Ihre Netzwerkverbindung ein.",
            @"Configure network settings": @"Netzwerkeinstellungen konfigurieren",
            @"Test connection": @"Verbindung testen",
            @"Verify connectivity": @"Konnektivität überprüfen"
        };
    }
    return germanTranslations;
}

+ (NSString *)localizedString:(NSString *)key {
    return [self localizedString:key fallback:key];
}

+ (NSString *)localizedString:(NSString *)key fallback:(NSString *)fallback {
    NSString *language = [self currentLanguage];
    
    if ([language isEqualToString:@"de"]) {
        NSDictionary *germanStrings = [self germanStrings];
        NSString *translation = germanStrings[key];
        if (translation) {
            return translation;
        }
    }
    
    // Fall back to the provided fallback (usually the original English text)
    return fallback ?: key;
}

@end
