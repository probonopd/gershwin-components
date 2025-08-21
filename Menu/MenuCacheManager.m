#import "MenuCacheManager.h"
#import "MenuUtils.h"

@implementation MenuCacheEntry

@synthesize menu = _menu;
@synthesize lastAccessed = _lastAccessed;
@synthesize cached = _cached;
@synthesize accessCount = _accessCount;
@synthesize serviceName = _serviceName;
@synthesize objectPath = _objectPath;
@synthesize applicationName = _applicationName;

- (id)initWithMenu:(NSMenu *)menu 
       serviceName:(NSString *)serviceName 
        objectPath:(NSString *)objectPath
   applicationName:(NSString *)applicationName
{
    self = [super init];
    if (self) {
        _menu = [menu retain];
        _cached = [NSDate timeIntervalSinceReferenceDate];
        _lastAccessed = _cached;
        _accessCount = 1;
        _serviceName = [serviceName retain];
        _objectPath = [objectPath retain];
        _applicationName = [applicationName retain];
    }
    return self;
}

- (void)dealloc
{
    [_menu release];
    [_serviceName release];
    [_objectPath release];
    [_applicationName release];
    [super dealloc];
}

- (void)touch
{
    _lastAccessed = [NSDate timeIntervalSinceReferenceDate];
    _accessCount++;
}

- (NSTimeInterval)age
{
    return [NSDate timeIntervalSinceReferenceDate] - _cached;
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

@implementation MenuCacheManager

static MenuCacheManager *sharedInstance = nil;

+ (MenuCacheManager *)sharedManager
{
    if (!sharedInstance) {
        sharedInstance = [[MenuCacheManager alloc] init];
    }
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _cache = [[NSMutableDictionary alloc] init];
        _lruOrder = [[NSMutableArray alloc] init];
        _maxCacheSize = 50;    // Increased cache size for complex apps like GIMP
        _maxCacheAge = 1800.0; // 30 minutes cache age for better persistence
        
        // Initialize statistics
        _cacheHits = 0;
        _cacheMisses = 0;
        _cacheEvictions = 0;
        
        // Set up periodic maintenance (less frequent to avoid disruption)
        _cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:120.0  // Every 2 minutes
                                                        target:self
                                                      selector:@selector(performMaintenance)
                                                      userInfo:nil
                                                       repeats:YES];
        
        NSLog(@"MenuCacheManager: Initialized with maxSize=%lu maxAge=%.1fs", 
              (unsigned long)_maxCacheSize, _maxCacheAge);
    }
    return self;
}

- (void)dealloc
{
    [_cleanupTimer invalidate];
    [_cache release];
    [_lruOrder release];
    [super dealloc];
}

#pragma mark - Cache Operations

- (NSMenu *)getCachedMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    MenuCacheEntry *entry = [_cache objectForKey:windowKey];
    
    if (!entry) {
        _cacheMisses++;
        NSLog(@"MenuCacheManager: Cache MISS for window %lu", windowId);
        return nil;
    }
    
    // Check if entry is stale
    if ([entry isStale:_maxCacheAge]) {
        NSLog(@"MenuCacheManager: Cache entry for window %lu is stale (age: %.1fs), removing", 
              windowId, [entry age]);
        [self invalidateCacheForWindow:windowId];
        _cacheMisses++;
        return nil;
    }
    
    // Update access tracking
    [entry touch];
    [self moveToFront:windowKey];
    
    _cacheHits++;
    NSLog(@"MenuCacheManager: Cache HIT for window %lu (accessed %lu times, age: %.1fs)", 
          windowId, (unsigned long)[entry accessCount], [entry age]);
    
    return [entry menu];
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
    
    // Remove existing entry if present
    [self invalidateCacheForWindow:windowId];
    
    // Ensure we don't exceed cache size limit
    while ([_cache count] >= _maxCacheSize && [_lruOrder count] > 0) {
        [self evictLRUEntry];
    }
    
    // Create new cache entry
    MenuCacheEntry *entry = [[MenuCacheEntry alloc] initWithMenu:menu
                                                     serviceName:serviceName
                                                      objectPath:objectPath
                                                 applicationName:applicationName];
    
    [_cache setObject:entry forKey:windowKey];
    [_lruOrder insertObject:windowKey atIndex:0];  // Add to front (most recent)
    
    NSLog(@"MenuCacheManager: Cached menu for window %lu (%@ - %@) with %lu items", 
          windowId, applicationName ?: @"Unknown App", serviceName, 
          (unsigned long)[[menu itemArray] count]);
    
    [entry release];
}

- (void)invalidateCacheForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    MenuCacheEntry *entry = [_cache objectForKey:windowKey];
    
    if (entry) {
        NSLog(@"MenuCacheManager: Invalidating cache for window %lu (%@)", 
              windowId, [entry applicationName] ?: @"Unknown App");
        
        [_cache removeObjectForKey:windowKey];
        [_lruOrder removeObject:windowKey];
    }
}

- (void)invalidateCacheForApplication:(NSString *)applicationName
{
    if (!applicationName) {
        return;
    }
    
    NSLog(@"MenuCacheManager: Invalidating cache for application: %@", applicationName);
    
    NSMutableArray *windowsToRemove = [NSMutableArray array];
    
    for (NSNumber *windowKey in [_cache allKeys]) {
        MenuCacheEntry *entry = [_cache objectForKey:windowKey];
        if ([[entry applicationName] isEqualToString:applicationName]) {
            [windowsToRemove addObject:windowKey];
        }
    }
    
    for (NSNumber *windowKey in windowsToRemove) {
        unsigned long windowId = [windowKey unsignedLongValue];
        [self invalidateCacheForWindow:windowId];
    }
    
    NSLog(@"MenuCacheManager: Invalidated %lu cached menus for application %@", 
          (unsigned long)[windowsToRemove count], applicationName);
}

- (void)clearCache
{
    NSUInteger count = [_cache count];
    [_cache removeAllObjects];
    [_lruOrder removeAllObjects];
    
    NSLog(@"MenuCacheManager: Cleared entire cache (%lu entries)", (unsigned long)count);
}

#pragma mark - Cache Management

- (void)setMaxCacheSize:(NSUInteger)maxSize
{
    _maxCacheSize = maxSize;
    NSLog(@"MenuCacheManager: Set max cache size to %lu", (unsigned long)maxSize);
    
    // Evict entries if we're now over the limit
    while ([_cache count] > _maxCacheSize && [_lruOrder count] > 0) {
        [self evictLRUEntry];
    }
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
    for (NSNumber *windowKey in [_cache allKeys]) {
        MenuCacheEntry *entry = [_cache objectForKey:windowKey];
        if ([entry isStale:_maxCacheAge]) {
            [staleWindows addObject:windowKey];
        }
    }
    
    // Remove stale entries
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

- (void)evictLRUEntry
{
    if ([_lruOrder count] == 0) {
        return;
    }
    
    NSNumber *lruWindowKey = [_lruOrder lastObject];
    unsigned long windowId = [lruWindowKey unsignedLongValue];
    
    MenuCacheEntry *entry = [_cache objectForKey:lruWindowKey];
    NSLog(@"MenuCacheManager: Evicting LRU entry for window %lu (%@)", 
          windowId, [entry applicationName] ?: @"Unknown App");
    
    [_cache removeObjectForKey:lruWindowKey];
    [_lruOrder removeLastObject];
    _cacheEvictions++;
}

- (void)moveToFront:(NSNumber *)windowKey
{
    [_lruOrder removeObject:windowKey];
    [_lruOrder insertObject:windowKey atIndex:0];
}

#pragma mark - Statistics

- (NSDictionary *)getCacheStatistics
{
    NSUInteger totalRequests = _cacheHits + _cacheMisses;
    double hitRatio = (totalRequests > 0) ? ((double)_cacheHits / totalRequests) * 100.0 : 0.0;
    
    return @{
        @"cacheSize": @([_cache count]),
        @"maxCacheSize": @(_maxCacheSize),
        @"maxCacheAge": @(_maxCacheAge),
        @"cacheHits": @(_cacheHits),
        @"cacheMisses": @(_cacheMisses),
        @"cacheEvictions": @(_cacheEvictions),
        @"hitRatio": @(hitRatio),
        @"totalRequests": @(totalRequests)
    };
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
    
    // Log current cache contents
    if ([_cache count] > 0) {
        NSLog(@"MenuCacheManager: Cached windows:");
        for (NSNumber *windowKey in _lruOrder) {
            MenuCacheEntry *entry = [_cache objectForKey:windowKey];
            NSLog(@"MenuCacheManager:   Window %@ (%@): %lu items, age %.1fs, accessed %lu times",
                  windowKey, [entry applicationName] ?: @"Unknown",
                  (unsigned long)[[entry menu] numberOfItems],
                  [entry age], (unsigned long)[entry accessCount]);
        }
    }
    NSLog(@"MenuCacheManager: ========================");
}

#pragma mark - Window Lifecycle

- (void)windowBecameActive:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    MenuCacheEntry *entry = [_cache objectForKey:windowKey];
    
    if (entry) {
        [entry touch];
        [self moveToFront:windowKey];
        NSLog(@"MenuCacheManager: Window %lu became active, moved to cache front", windowId);
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
