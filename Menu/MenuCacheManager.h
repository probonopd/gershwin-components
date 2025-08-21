#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface MenuCacheEntry : NSObject
{
    NSMenu *_menu;
    NSTimeInterval _lastAccessed;
    NSTimeInterval _cached;
    NSUInteger _accessCount;
    NSString *_serviceName;
    NSString *_objectPath;
    NSString *_applicationName;
}

@property (nonatomic, retain) NSMenu *menu;
@property (nonatomic, assign) NSTimeInterval lastAccessed;
@property (nonatomic, assign) NSTimeInterval cached;
@property (nonatomic, assign) NSUInteger accessCount;
@property (nonatomic, retain) NSString *serviceName;
@property (nonatomic, retain) NSString *objectPath;
@property (nonatomic, retain) NSString *applicationName;

- (id)initWithMenu:(NSMenu *)menu 
       serviceName:(NSString *)serviceName 
        objectPath:(NSString *)objectPath
   applicationName:(NSString *)applicationName;
- (void)touch;
- (NSTimeInterval)age;
- (BOOL)isStale:(NSTimeInterval)maxAge;

@end

@interface MenuCacheManager : NSObject
{
    NSMutableDictionary *_cache;               // windowId -> MenuCacheEntry
    NSMutableArray *_lruOrder;                 // Array of window IDs in LRU order
    NSUInteger _maxCacheSize;
    NSTimeInterval _maxCacheAge;
    NSTimer *_cleanupTimer;
    
    // Statistics
    NSUInteger _cacheHits;
    NSUInteger _cacheMisses;
    NSUInteger _cacheEvictions;
}

+ (MenuCacheManager *)sharedManager;

// Cache operations
- (NSMenu *)getCachedMenuForWindow:(unsigned long)windowId;
- (void)cacheMenu:(NSMenu *)menu 
        forWindow:(unsigned long)windowId 
      serviceName:(NSString *)serviceName 
       objectPath:(NSString *)objectPath
  applicationName:(NSString *)applicationName;
- (void)invalidateCacheForWindow:(unsigned long)windowId;
- (void)invalidateCacheForApplication:(NSString *)applicationName;
- (void)clearCache;

// Cache management
- (void)setMaxCacheSize:(NSUInteger)maxSize;
- (void)setMaxCacheAge:(NSTimeInterval)maxAge;
- (void)performMaintenance;

// Statistics
- (NSDictionary *)getCacheStatistics;
- (void)logCacheStatistics;

// Window lifecycle
- (void)windowBecameActive:(unsigned long)windowId;
- (void)windowBecameInactive:(unsigned long)windowId;
- (void)applicationSwitched:(NSString *)fromApp toApp:(NSString *)toApp;

// Application classification
- (BOOL)isComplexApplication:(NSString *)applicationName;

@end
