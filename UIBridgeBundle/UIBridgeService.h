/*
 * UIBridgeService — implements UIBridgeProtocol against the live AppKit tree.
 *
 * Extracted from the Eau theme (Eau.m) so the introspection/automation service
 * is theme-independent. Two deliberate changes vs. the in-theme version:
 *
 *   1. Object identity goes through a real id<->object registry (a weak
 *      NSMapTable), NOT a raw hex-pointer cast. Looking up a dead id returns
 *      nil instead of resurrecting a freed pointer (kills the use-after-free).
 *
 *   2. No -enableMultipleThreads. The service is vended single-threaded on the
 *      main run loop, so DO requests run on the main thread and never race the
 *      app's drawing / autorelease-pool chain.
 *
 * The class depends only on NSApp, never on the active theme.
 */

#import <AppKit/AppKit.h>
#import "UIBridgeProtocol.h"

@interface UIBridgeService : NSObject <UIBridgeProtocol>
{
  NSMapTable *_idToObject;   /* objc:<n> (strong)  -> object (weak)        */
  NSMapTable *_objectToID;   /* object (weak)      -> objc:<n> (strong)    */
  NSUInteger  _idCounter;
}
@end
