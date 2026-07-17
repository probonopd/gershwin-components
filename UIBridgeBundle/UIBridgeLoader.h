/*
 * UIBridgeLoader — principal class of UIBridge.bundle.
 *
 * AppKit instantiates this when the bundle is autoloaded via the
 * GSAppKitUserBundles user default. It registers a per-PID Distributed Objects
 * service vending a UIBridgeService, on the main run loop only.
 */

#import <AppKit/AppKit.h>

@interface UIBridgeLoader : NSObject
@end
