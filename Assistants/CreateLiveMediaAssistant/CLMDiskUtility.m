//
// CLMDiskUtility.m
// Create Live Media Assistant - Disk Utility
//

#import "CLMDiskUtility.h"

@implementation CLMDisk

@synthesize deviceName, description, size, geomName, isRemovable, isWritable;

- (void)dealloc
{
    [deviceName release];
    [description release];
    [geomName release];
    [super dealloc];
}

@end

@implementation CLMDiskUtility

+ (NSArray *)getAvailableDisks
{
    NSLog(@"CLMDiskUtility: getAvailableDisks");
    
    NSMutableArray *disks = [NSMutableArray array];
    
    // Use geom to get disk status
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/sbin/geom"];
    [task setArguments:@[@"disk", @"status", @"-s"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    
    NSFileHandle *file = [pipe fileHandleForReading];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        NSData *data = [file readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        
        for (NSString *line in lines) {
            NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([trimmedLine length] == 0) continue;
            
            NSArray *components = [trimmedLine componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSMutableArray *filteredComponents = [NSMutableArray array];
            
            for (NSString *component in components) {
                if ([component length] > 0) {
                    [filteredComponents addObject:component];
                }
            }
            
            if ([filteredComponents count] >= 3) {
                NSString *deviceName = [filteredComponents objectAtIndex:0];
                
                // Get detailed disk info
                CLMDisk *disk = [self getDiskInfo:deviceName];
                if (disk && disk.size > 0) {
                    [disks addObject:disk];
                }
            }
        }
        
        [output release];
    }
    @catch (NSException *exception) {
        NSLog(@"CLMDiskUtility: Error running geom: %@", [exception reason]);
    }
    
    [task release];
    
    NSLog(@"CLMDiskUtility: Found %lu disks", (unsigned long)[disks count]);
    return disks;
}

+ (CLMDisk *)getDiskInfo:(NSString *)deviceName
{
    NSLog(@"CLMDiskUtility: getDiskInfo: %@", deviceName);
    
    // Use geom to get detailed disk information
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/sbin/geom"];
    [task setArguments:@[@"disk", @"list", deviceName]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    
    NSFileHandle *file = [pipe fileHandleForReading];
    
    CLMDisk *disk = nil;
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        NSData *data = [file readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        disk = [[CLMDisk alloc] init];
        disk.deviceName = deviceName;
        disk.geomName = deviceName;
        disk.description = @"Unknown Device";
        disk.size = 0;
        disk.isRemovable = [deviceName hasPrefix:@"da"]; // USB drives typically start with 'da'
        disk.isWritable = YES;
        
        // Parse geom output
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        
        for (NSString *line in lines) {
            NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            if ([trimmedLine containsString:@"descr:"]) {
                NSRange range = [trimmedLine rangeOfString:@"descr:"];
                if (range.location != NSNotFound) {
                    NSString *desc = [trimmedLine substringFromIndex:range.location + range.length];
                    desc = [desc stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if ([desc length] > 0) {
                        disk.description = desc;
                    }
                }
            }
            else if ([trimmedLine containsString:@"Mediasize:"]) {
                NSRange range = [trimmedLine rangeOfString:@"Mediasize:"];
                if (range.location != NSNotFound) {
                    NSString *sizeStr = [trimmedLine substringFromIndex:range.location + range.length];
                    sizeStr = [sizeStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    
                    // Extract the number part (before any parentheses)
                    NSRange parenRange = [sizeStr rangeOfString:@" "];
                    if (parenRange.location != NSNotFound) {
                        sizeStr = [sizeStr substringToIndex:parenRange.location];
                    }
                    
                    disk.size = [sizeStr longLongValue];
                }
            }
        }
        
        [output release];
        
        // Don't return CD-ROM drives for now
        if ([deviceName hasPrefix:@"cd"]) {
            [disk release];
            disk = nil;
        }
        
    }
    @catch (NSException *exception) {
        NSLog(@"CLMDiskUtility: Error getting disk info: %@", [exception reason]);
        [disk release];
        disk = nil;
    }
    
    [task release];
    
    return [disk autorelease];
}

+ (BOOL)unmountPartitionsForDisk:(NSString *)deviceName
{
    NSLog(@"CLMDiskUtility: unmountPartitionsForDisk: %@", deviceName);
    
    // Find all partitions for this disk
    NSString *diskPattern = [NSString stringWithFormat:@"/dev/%@*", deviceName];
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:@[@"-c", [NSString stringWithFormat:@"ls %@ 2>/dev/null || true", diskPattern]]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    
    NSFileHandle *file = [pipe fileHandleForReading];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        NSData *data = [file readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        NSArray *partitions = [output componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        for (NSString *partition in partitions) {
            if ([partition length] > 0) {
                // Try to unmount each partition
                NSTask *umountTask = [[NSTask alloc] init];
                [umountTask setLaunchPath:@"/sbin/umount"];
                [umountTask setArguments:@[partition]];
                
                @try {
                    [umountTask launch];
                    [umountTask waitUntilExit];
                    NSLog(@"CLMDiskUtility: Unmounted %@", partition);
                }
                @catch (NSException *exception) {
                    NSLog(@"CLMDiskUtility: Could not unmount %@: %@", partition, [exception reason]);
                }
                
                [umountTask release];
            }
        }
        
        [output release];
    }
    @catch (NSException *exception) {
        NSLog(@"CLMDiskUtility: Error finding partitions: %@", [exception reason]);
        [task release];
        return NO;
    }
    
    [task release];
    return YES;
}

+ (NSString *)formatSize:(long long)sizeInBytes
{
    if (sizeInBytes >= 1024LL * 1024LL * 1024LL) {
        double gib = (double)sizeInBytes / (1024.0 * 1024.0 * 1024.0);
        return [NSString stringWithFormat:@"%.1f GiB", gib];
    } else if (sizeInBytes >= 1024LL * 1024LL) {
        double mib = (double)sizeInBytes / (1024.0 * 1024.0);
        return [NSString stringWithFormat:@"%.1f MiB", mib];
    } else {
        double kib = (double)sizeInBytes / 1024.0;
        return [NSString stringWithFormat:@"%.1f KiB", kib];
    }
}

@end
