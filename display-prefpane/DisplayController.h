#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class DisplayView;

// Represents a single display configuration
@interface DisplayInfo : NSObject
{
    NSString *name;
    NSRect frame;
    NSSize resolution;
    BOOL isPrimary;
    BOOL isConnected;
    NSString *output; // xrandr output name
}

@property (retain) NSString *name;
@property NSRect frame;
@property NSSize resolution;
@property BOOL isPrimary;
@property BOOL isConnected;
@property (retain) NSString *output;

@end

@interface DisplayController : NSObject
{
    NSMutableArray *displays;
    DisplayView *displayView;
    NSView *mainView;
    NSPopUpButton *resolutionPopup;
    NSButton *mirrorDisplaysCheckbox;
    NSButton *gatherWindowsButton;
    NSString *xrandrPath;
    DisplayInfo *selectedDisplay; // Currently selected display for resolution changes
}

- (NSView *)createMainView;
- (void)refreshDisplays:(NSTimer *)timer;
- (void)parseXrandrOutput:(NSString *)output;
- (void)applyDisplayConfiguration;
- (void)setPrimaryDisplay:(DisplayInfo *)display;
- (NSArray *)displays;
- (NSArray *)getAvailableResolutionsForDisplay:(DisplayInfo *)display;
- (void)showResolutionConfirmationDialogWithOldResolution:(NSString *)oldRes 
                                           newResolution:(NSString *)newRes 
                                                 display:(DisplayInfo *)display;
- (void)revertResolutionTimer:(NSTimer *)timer;
- (void)revertToResolution:(NSString *)resolution forDisplay:(DisplayInfo *)display;
- (void)resolutionCountdownTimer:(NSTimer *)timer;
- (void)resolutionRevertClicked:(id)sender;
- (void)resolutionKeepClicked:(id)sender;
- (void)selectDisplay:(DisplayInfo *)display;
- (DisplayInfo *)selectedDisplay;
- (NSString *)findXrandrPath;
- (BOOL)isXrandrAvailable;
- (void)autoConfigureDisplays;

@end
