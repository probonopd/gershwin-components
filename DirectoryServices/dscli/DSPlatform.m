#import "DSPlatform.h"

// Forward declarations for platform implementations
@interface DSPlatformFreeBSD : NSObject <DSPlatform>
@end

@interface DSPlatformLinux : NSObject <DSPlatform>
@end

id<DSPlatform> DSPlatformCreate(void)
{
#if defined(__FreeBSD__) || defined(__DragonFly__)
    return [[DSPlatformFreeBSD alloc] init];
#elif defined(__linux__)
    return [[DSPlatformLinux alloc] init];
#else
    return nil;
#endif
}
