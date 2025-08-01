#ifndef MB_SERVICE_MANAGER_H
#define MB_SERVICE_MANAGER_H

#import <Foundation/Foundation.h>

@class MBServiceFile;

/**
 * MBServiceManager - Manages D-Bus service activation
 * 
 * Handles:
 * - Service file discovery and parsing
 * - Service activation (launching processes)
 * - Environment setup for activated services
 */
@interface MBServiceManager : NSObject
{
    NSMutableDictionary *_services; // service name -> MBServiceFile
    NSArray *_servicePaths;         // Directories to search for .service files
    NSMutableDictionary *_activatingServices; // service name -> NSDate (activation start time)
}

/**
 * Initialize with service directories to search
 */
- (instancetype)initWithServicePaths:(NSArray *)servicePaths;

/**
 * Scan service directories and load all .service files
 */
- (void)loadServices;

/**
 * Check if a service is available for activation
 */
- (BOOL)hasService:(NSString *)serviceName;

/**
 * Get service file for a service name
 */
- (MBServiceFile *)serviceFileForName:(NSString *)serviceName;

/**
 * Activate a service (launch the process)
 * Returns YES if activation was started successfully
 * The service will take some time to connect to the bus
 */
- (BOOL)activateService:(NSString *)serviceName 
            busAddress:(NSString *)busAddress
                busType:(NSString *)busType  // "session" or "system"
                  error:(NSError **)error;

/**
 * Check if a service is currently being activated
 */
- (BOOL)isActivatingService:(NSString *)serviceName;

/**
 * Mark that a service activation completed (called when service connects)
 */
- (void)serviceActivationCompleted:(NSString *)serviceName;

/**
 * Get list of all available service names
 */
- (NSArray *)availableServiceNames;

@end

#endif // MB_SERVICE_MANAGER_H
