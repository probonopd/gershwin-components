#ifndef MB_SERVICE_FILE_H
#define MB_SERVICE_FILE_H

#import <Foundation/Foundation.h>

/**
 * MBServiceFile - Parser for D-Bus .service files
 * 
 * Parses service description files that define how to activate D-Bus services.
 * Service files have the format:
 * 
 * [D-BUS Service]
 * Name=com.example.Service
 * Exec=/path/to/executable
 * User=username (for system services only)
 * SystemdService=systemd-service-name (optional)
 * AssumedAppArmorLabel=/path/label (optional)
 */
@interface MBServiceFile : NSObject

@property (nonatomic, readonly) NSString *serviceName;
@property (nonatomic, readonly) NSString *executablePath;
@property (nonatomic, readonly) NSString *user;  // For system services
@property (nonatomic, readonly) NSString *systemdService;  // Optional systemd integration
@property (nonatomic, readonly) NSString *assumedAppArmorLabel;  // Optional AppArmor label

/**
 * Parse a service file from disk
 */
+ (instancetype)serviceFileFromPath:(NSString *)filePath;

/**
 * Parse service file from string content
 */
+ (instancetype)serviceFileFromContent:(NSString *)content;

/**
 * Validate that the service file is well-formed
 */
- (BOOL)isValid;

/**
 * Get the executable command line with arguments
 */
- (NSArray *)commandLineArguments;

@end

#endif // MB_SERVICE_FILE_H
