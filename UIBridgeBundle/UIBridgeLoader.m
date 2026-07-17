/*
 * UIBridgeLoader — see UIBridgeLoader.h.
 *
 * The per-PID DO name is unchanged from the in-theme service
 * (org.gershwin.Gershwin.Theme.UIBridge.<pid>) so the existing UIBridgeServer
 * finds it with no wire/protocol change.
 *
 * Threading: deliberately NO -enableMultipleThreads and NO connection
 * delegate. The receive port is added to the main run loop, so DO requests are
 * serviced on the main thread alongside AppKit — they cannot race the app's
 * drawing or corrupt its per-thread autorelease-pool chain.
 */

#import "UIBridgeLoader.h"
#import "UIBridgeService.h"

#ifdef UIBRIDGE_DEBUG
#define UBLOG(...) NSLog(__VA_ARGS__)
#else
#define UBLOG(...) do {} while (0)
#endif

static UIBridgeService *gService = nil;
static NSConnection    *gConnection = nil;

@implementation UIBridgeLoader

+ (void)load
{
  /* Register the service once AppKit is up. Observing the launch notification
     (rather than acting in +load) guarantees NSApp and the main run loop
     exist. */
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(_registerService:)
                                               name:NSApplicationDidFinishLaunchingNotification
                                             object:nil];
}

/* Belt-and-braces: if AppKit instantiates the principal class, still ensure
   the observer is in place (idempotent — duplicate observers are removed by
   name on first fire). */
- (id)init
{
  if ((self = [super init]) != nil) {
    [[NSNotificationCenter defaultCenter] addObserver:[self class]
                                             selector:@selector(_registerService:)
                                                 name:NSApplicationDidFinishLaunchingNotification
                                               object:nil];
  }
  return self;
}

+ (void)_registerService:(NSNotification *)note
{
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:NSApplicationDidFinishLaunchingNotification
                                                object:nil];
  if (gConnection) {
    UBLOG(@"UIBridge: service already registered, skipping");
    return;
  }
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self _registerService:nil]; });
    return;
  }

  pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
  NSString *name = [NSString stringWithFormat:@"org.gershwin.Gershwin.Theme.UIBridge.%d", pid];

  @try {
    gService = [[UIBridgeService alloc] init];

    gConnection = [[NSConnection alloc] init];
    [gConnection setRootObject:gService];
    /* Single-threaded: no enableMultipleThreads, no connection delegate. */

    NSPort *recvPort = [gConnection receivePort];
    NSRunLoop *rl = [NSRunLoop mainRunLoop];
    [rl addPort:recvPort forMode:NSDefaultRunLoopMode];
    [rl addPort:recvPort forMode:NSRunLoopCommonModes];
    [rl addPort:recvPort forMode:NSModalPanelRunLoopMode];
    [rl addPort:recvPort forMode:NSEventTrackingRunLoopMode];

    if ([gConnection registerName:name]) {
      UBLOG(@"UIBridge: registered per-PID service %@", name);
    } else {
      /* Another vendor (e.g. an older Eau that still self-registers) already
         holds the name — stand down rather than fight over it. */
      UBLOG(@"UIBridge: name %@ already registered, standing down", name);
      gConnection = nil;
      gService = nil;
    }
  } @catch (NSException *e) {
    UBLOG(@"UIBridge: registration failed: %@", e);
    gConnection = nil;
    gService = nil;
  }
}

@end
