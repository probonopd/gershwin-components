#import <Foundation/Foundation.h>

@interface GSUTMConfiguration : NSObject

@property (nonatomic, readonly) NSDictionary *rawPlist;

/* Info */
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *iconName;
@property (nonatomic, copy) NSString *notes;

/* System */
@property (nonatomic, copy) NSString *architecture; /* x86_64, aarch64 */
@property (nonatomic, copy) NSString *target;       /* q35, pc, virt */
@property (nonatomic, copy) NSString *cpu;          /* default, max, host */
@property (nonatomic) NSUInteger memorySize;        /* MB */
@property (nonatomic) NSUInteger cpuCount;
@property (nonatomic, copy) NSString *bootDevice;   /* cd, disk */

/* Drives */
@property (nonatomic, retain) NSMutableArray *drives; /* NSDictionary per drive */

/* Network */
@property (nonatomic, copy) NSString *networkCard;
@property (nonatomic) BOOL networkEnabled;

/* Sound */
@property (nonatomic, copy) NSString *soundCard;
@property (nonatomic) BOOL soundEnabled;

/* Sharing */
@property (nonatomic) BOOL clipboardSharing;
@property (nonatomic) BOOL directorySharing;

/* Input */
@property (nonatomic) BOOL inputLegacy;

/* Display */
@property (nonatomic, copy) NSString *consoleFont;
@property (nonatomic) int consoleFontSize;
@property (nonatomic, copy) NSString *consoleTheme;
@property (nonatomic, copy) NSString *displayUpscaler;
@property (nonatomic, copy) NSString *displayDownscaler;

/* Display card used for Linux host guests (e.g. virtio-vga, vmware-svga).
   Saved in the config under Display/LinuxHostDisplayCard. */
@property (nonatomic, copy) NSString *linuxHostDisplayCard;

/* Extra arguments */
@property (nonatomic, copy) NSString *extraArguments;

/* Device availability checking */
- (NSString *)availableDeviceFor:(NSString *)device arch:(NSString *)arch;
- (BOOL)isDeviceAvailable:(NSString *)device arch:(NSString *)arch;

/* Convenience accessors for the primary disk and cdrom paths */
@property (nonatomic, copy) NSString *diskImagePath;
@property (nonatomic, copy) NSString *cdromImagePath;

/* Base URL for resolving relative paths (set when loaded from a bundle) */
@property (nonatomic, retain) NSURL *baseURL;

- (instancetype)initWithPlist:(NSDictionary *)plist;
- (NSString *)qemuBinary;
- (NSArray<NSString *> *)qemuArguments;
- (void)resolveDrivePathsWithBaseURL:(NSURL *)baseURL;
- (BOOL)saveToURL:(NSURL *)url error:(NSError **)error;
+ (instancetype)loadFromURL:(NSURL *)url error:(NSError **)error;

@end
