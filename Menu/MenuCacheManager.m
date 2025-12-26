#import "MenuCacheManager.h"
#import "MenuUtils.h"

@implementation MenuCacheEntry

- (id)initWithMenu:(NSMenu *)menu 
       serviceName:(NSString *)serviceName 
        objectPath:(NSString *)objectPath
   applicationName:(NSString *)applicationName
{
    self = [super init];
    if (self) {
        self.menu = menu;
        self.cached = [NSDate timeIntervalSinceReferenceDate];
        self.lastAccessed = self.cached;
        self.accessCount = 1;
        self.serviceName = serviceName;
        self.objectPath = objectPath;
        self.applicationName = applicationName;
    }
    return self;
}

- (void)touch
{
    self.lastAccessed = [NSDate timeIntervalSinceReferenceDate];
    self.accessCount++;
}

- (NSTimeInterval)age
{
    return [NSDate timeIntervalSinceReferenceDate] - self.cached;
}

- (BOOL)isStale:(NSTimeInterval)maxAge
{
    NSTimeInterval effectiveMaxAge = maxAge;
    
    // Complex applications get 4x longer cache time
    if ([self isComplexApplication]) {
        effectiveMaxAge *= 4.0;
    }
    
    return [self age] > effectiveMaxAge;
}

- (BOOL)isComplexApplication
{
    return YES;
}

@end

@implementation MenuCacheManager {
    NSLock *_cacheLock;  // Thread-safe lock for cache and lruOrder
}

+ (MenuCacheManager *)sharedManager
{
    static MenuCacheManager *sharedInstance = nil;
    @synchronized(self) {
        if (!sharedInstance) {
            sharedInstance = [[MenuCacheManager alloc] init];
        }
    }
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _cacheLock = [[NSLock alloc] init];
        self.cache = [[NSMutableDictionary alloc] init];
        self.lruOrder = [[NSMutableArray alloc] init];
        _maxCacheSize = 50;    // Increased cache size for complex apps like GIMP
        _maxCacheAge = 1800.0; // 30 minutes cache age for better persistence
        
        // Initialize statistics
        self.cacheHits = 0;
        self.cacheMisses = 0;
        self.cacheEvictions = 0;
        
        // Set up periodic maintenance (less frequent to avoid disruption)
        self.cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:120.0  // Every 2 minutes
                                                        target:self
                                                      selector:@selector(performMaintenance)
                                                      userInfo:nil
                                                       repeats:YES];
        
        NSLog(@"MenuCacheManager: Initialized with maxSize=%lu maxAge=%.1fs", 
              (unsigned long)_maxCacheSize, _maxCacheAge);
    }
    return self;
}

#pragma mark - Cache Operations

- (NSMenu *)getCachedMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_cacheLock lock];
    MenuCacheEntry *entry = [self.cache objectForKey:windowKey];
    
    if (!entry) {
        self.cacheMisses++;
        [_cacheLock unlock];
        NSLog(@"MenuCacheManager: Cache MISS for window %lu", windowId);
        return nil;
    }
    
    // Check if entry is stale
    if ([entry isStale:self.maxCacheAge]) {
        NSTimeInterval age = [entry age];
        [_cacheLock unlock];
        NSLog(@"MenuCacheManager: Cache entry for window %lu is stale (age: %.1fs), removing", 
              windowId, age);
        [self invalidateCacheForWindow:windowId];
        [_cacheLock lock];
        self.cacheMisses++;
        [_cacheLock unlock];
        return nil;
    }
    
    // Update access tracking
    [entry touch];
    [self moveToFrontLocked:windowKey];
    
    self.cacheHits++;
    NSMenu *menu = [entry menu];
    NSUInteger accessCount = [entry accessCount];
    NSTimeInterval age = [entry age];
    [_cacheLock unlock];
    
    NSLog(@"MenuCacheManager: Cache HIT for window %lu (accessed %lu times, age: %.1fs)", 
          windowId, (unsigned long)accessCount, age);
    
    return menu;
}

- (void)cacheMenu:(NSMenu *)menu 
        forWindow:(unsigned long)windowId 
      serviceName:(NSString *)serviceName 
       objectPath:(NSString *)objectPath
  applicationName:(NSString *)applicationName
{
    if (!menu) {
        NSLog(@"MenuCacheManager: Cannot cache nil menu for window %lu", windowId);
        return;
    }
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    // Remove existing entry if present (uses lock internally)
    [self invalidateCacheForWindow:windowId];
    
    [_cacheLock lock];
    // Ensure we don't exceed cache size limit
    while ([self.cache count] >= self.maxCacheSize && [self.lruOrder count] > 0) {
        [self evictLRUEntryLocked];
    }
    
    // Create new cache entry
    MenuCacheEntry *entry = [[MenuCacheEntry alloc] initWithMenu:menu
                                                     serviceName:serviceName
                                                      objectPath:objectPath
                                                 applicationName:applicationName];
    
    [self.cache setObject:entry forKey:windowKey];
    [self.lruOrder insertObject:windowKey atIndex:0];  // Add to front (most recent)
    [_cacheLock unlock];
    
    NSLog(@"MenuCacheManager: Cached menu for window %lu (%@ - %@) with %lu items", 
          windowId, applicationName ?: @"Unknown App", serviceName, 
          (unsigned long)[[menu itemArray] count]);
}

- (void)invalidateCacheForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_cacheLock lock];
    MenuCacheEntry *entry = [self.cache objectForKey:windowKey];
    
    if (entry) {
        NSString *appName = [[entry applicationName] copy];
        [self.cache removeObjectForKey:windowKey];
        [self.lruOrder removeObject:windowKey];
        [_cacheLock unlock];
        
        NSLog(@"MenuCacheManager: Invalidating cache for window %lu (%@)", 
              windowId, appName ?: @"Unknown App");
    } else {
        [_cacheLock unlock];
    }
}

- (void)invalidateCacheForApplication:(NSString *)applicationName
{
    if (!applicationName) {
        return;
    }
    
    NSLog(@"MenuCacheManager: Invalidating cache for application: %@", applicationName);
    
    NSMutableArray *windowsToRemove = [NSMutableArray array];
    
    [_cacheLock lock];
    for (NSNumber *windowKey in [self.cache allKeys]) {
        MenuCacheEntry *entry = [self.cache objectForKey:windowKey];
        if ([[entry applicationName] isEqualToString:applicationName]) {
            [windowsToRemove addObject:windowKey];
        }
    }
    [_cacheLock unlock];
    
    for (NSNumber *windowKey in windowsToRemove) {
        unsigned long windowId = [windowKey unsignedLongValue];
        [self invalidateCacheForWindow:windowId];
    }
    
    NSLog(@"MenuCacheManager: Invalidated %lu cached menus for application %@", 
          (unsigned long)[windowsToRemove count], applicationName);
}

- (void)clearCache
{
    [_cacheLock lock];
    NSUInteger count = [self.cache count];
    [self.cache removeAllObjects];
    [self.lruOrder removeAllObjects];
    [_cacheLock unlock];
    
    NSLog(@"MenuCacheManager: Cleared entire cache (%lu entries)", (unsigned long)count);
}

#pragma mark - Cache Management

- (void)setMaxCacheSize:(NSUInteger)maxSize
{
    _maxCacheSize = maxSize;
    NSLog(@"MenuCacheManager: Set max cache size to %lu", (unsigned long)maxSize);
    
    // Evict entries if we're now over the limit
    [_cacheLock lock];
    while ([self.cache count] > _maxCacheSize && [self.lruOrder count] > 0) {
        [self evictLRUEntryLocked];
    }
    [_cacheLock unlock];
}

- (void)setMaxCacheAge:(NSTimeInterval)maxAge
{
    _maxCacheAge = maxAge;
    NSLog(@"MenuCacheManager: Set max cache age to %.1fs", maxAge);
}

- (void)performMaintenance
{
    NSMutableArray *staleWindows = [NSMutableArray array];
    
    // Find stale entries
    [_cacheLock lock];
    for (NSNumber *windowKey in [self.cache allKeys]) {
        MenuCacheEntry *entry = [self.cache objectForKey:windowKey];
        if ([entry isStale:self.maxCacheAge]) {
            [staleWindows addObject:windowKey];
        }
    }
    [_cacheLock unlock];
    
    // Remove stale entries (invalidateCacheForWindow has its own locking)
    for (NSNumber *windowKey in staleWindows) {
        unsigned long windowId = [windowKey unsignedLongValue];
        NSLog(@"MenuCacheManager: Removing stale cache entry for window %lu", windowId);
        [self invalidateCacheForWindow:windowId];
    }
    
    if ([staleWindows count] > 0) {
        NSLog(@"MenuCacheManager: Maintenance removed %lu stale entries", 
              (unsigned long)[staleWindows count]);
    }
    
    // Log statistics periodically (every 10 minutes)
    static NSUInteger maintenanceCount = 0;
    maintenanceCount++;
    if (maintenanceCount % 10 == 0) {
        [self logCacheStatistics];
    }
}

// Internal locked version - caller must hold _cacheLock
- (void)evictLRUEntryLocked
{
    if ([self.lruOrder count] == 0) {
        return;
    }
    
    NSNumber *lruWindowKey = [self.lruOrder lastObject];
    unsigned long windowId = [lruWindowKey unsignedLongValue];
    
    MenuCacheEntry *entry = [self.cache objectForKey:lruWindowKey];
    NSString *appName = [[entry applicationName] copy];
    
    [self.cache removeObjectForKey:lruWindowKey];
    [self.lruOrder removeLastObject];
    self.cacheEvictions++;
    
    NSLog(@"MenuCacheManager: Evicting LRU entry for window %lu (%@)", 
          windowId, appName ?: @"Unknown App");
}

// Public version with locking
- (void)evictLRUEntry
{
    [_cacheLock lock];
    [self evictLRUEntryLocked];
    [_cacheLock unlock];
}

// Internal locked version - caller must hold _cacheLock
- (void)moveToFrontLocked:(NSNumber *)windowKey
{
    [self.lruOrder removeObject:windowKey];
    [self.lruOrder insertObject:windowKey atIndex:0];
}

// Public version with locking
- (void)moveToFront:(NSNumber *)windowKey
{
    [_cacheLock lock];
    [self moveToFrontLocked:windowKey];
    [_cacheLock unlock];
}

#pragma mark - Statistics

- (NSDictionary *)getCacheStatistics
{
    [_cacheLock lock];
    NSUInteger totalRequests = self.cacheHits + self.cacheMisses;
    double hitRatio = (totalRequests > 0) ? ((double)self.cacheHits / totalRequests) * 100.0 : 0.0;
    
    NSDictionary *stats = @{
        @"cacheSize": @([self.cache count]),
        @"maxCacheSize": @(self.maxCacheSize),
        @"maxCacheAge": @(self.maxCacheAge),
        @"cacheHits": @(self.cacheHits),
        @"cacheMisses": @(self.cacheMisses),
        @"cacheEvictions": @(self.cacheEvictions),
        @"hitRatio": @(hitRatio),
        @"totalRequests": @(totalRequests)
    };
    [_cacheLock unlock];
    
    return stats;
}

- (void)logCacheStatistics
{
    NSDictionary *stats = [self getCacheStatistics];
    
    NSLog(@"MenuCacheManager: === CACHE STATISTICS ===");
    NSLog(@"MenuCacheManager: Cache size: %@ / %@", stats[@"cacheSize"], stats[@"maxCacheSize"]);
    NSLog(@"MenuCacheManager: Cache hits: %@, misses: %@, evictions: %@", 
          stats[@"cacheHits"], stats[@"cacheMisses"], stats[@"cacheEvictions"]);
    NSLog(@"MenuCacheManager: Hit ratio: %.1f%% (%@ total requests)", 
          [stats[@"hitRatio"] doubleValue], stats[@"totalRequests"]);
    NSLog(@"MenuCacheManager: Max cache age: %.1fs", [stats[@"maxCacheAge"] doubleValue]);
    
    // Log current cache contents with thread safety
    [_cacheLock lock];
    if ([self.cache count] > 0) {
        NSLog(@"MenuCacheManager: Cached windows:");
        for (NSNumber *windowKey in self.lruOrder) {
            MenuCacheEntry *entry = [self.cache objectForKey:windowKey];
            if (entry) {
                NSLog(@"MenuCacheManager:   Window %@ (%@): %lu items, age %.1fs, accessed %lu times",
                      windowKey, [entry applicationName] ?: @"Unknown",
                      (unsigned long)[[entry menu] numberOfItems],
                      [entry age], (unsigned long)[entry accessCount]);
            }
        }
    }
    [_cacheLock unlock];
    NSLog(@"MenuCacheManager: ========================");
}

#pragma mark - Window Lifecycle

- (void)windowBecameActive:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_cacheLock lock];
    MenuCacheEntry *entry = [self.cache objectForKey:windowKey];
    
    if (entry) {
        [entry touch];
        [self moveToFrontLocked:windowKey];
        [_cacheLock unlock];
        NSLog(@"MenuCacheManager: Window %lu became active, moved to cache front", windowId);
    } else {
        [_cacheLock unlock];
    }
}

- (void)windowBecameInactive:(unsigned long)windowId
{
    // Currently no special handling for inactive windows
    // Could implement priority reduction here if needed
}

- (void)applicationSwitched:(NSString *)fromApp toApp:(NSString *)toApp
{
    NSLog(@"MenuCacheManager: Application switched from '%@' to '%@'", 
          fromApp ?: @"Unknown", toApp ?: @"Unknown");
    
    // For complex applications like GIMP, increase cache persistence
    if ([self isComplexApplication:toApp]) {
        NSLog(@"MenuCacheManager: Detected complex application '%@', using extended cache persistence", toApp);
        // Complex apps get longer cache time
        // This is handled per-entry in the cache logic
    }
    
    // Could implement application-level cache prioritization here
    // For now, just log the switch for debugging
}

- (BOOL)isComplexApplication:(NSString *)applicationName
{
    if (!applicationName) {
        return NO;
    }
    
    // List of applications known to have complex menus that benefit from aggressive caching
    NSArray *complexApps = @[
        @"gimp",
        @"GIMP",
        @"gimp-2.10",
        @"inkscape",
        @"Inkscape", 
        @"blender",
        @"Blender",
        @"libreoffice",
        @"LibreOffice",
        @"firefox",
        @"Firefox",
        @"thunderbird",
        @"Thunderbird",
        @"eclipse",
        @"Eclipse",
        @"netbeans",
        @"NetBeans",
        @"code",
        @"Code",
        @"visual-studio-code",
        @"qtcreator",
        @"Qt Creator"
    ];
    
    NSString *lowerAppName = [applicationName lowercaseString];
    for (NSString *complexApp in complexApps) {
        if ([lowerAppName containsString:[complexApp lowercaseString]]) {
            return YES;
        }
    }
    
    return NO;
}

@end
