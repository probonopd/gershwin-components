#import "MBServiceFile.h"

@implementation MBServiceFile

+ (instancetype)serviceFileFromPath:(NSString *)filePath
{
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:filePath 
                                                   encoding:NSUTF8StringEncoding 
                                                      error:&error];
    if (!content) {
        NSLog(@"Failed to read service file %@: %@", filePath, error.localizedDescription);
        return nil;
    }
    
    return [self serviceFileFromContent:content];
}

+ (instancetype)serviceFileFromContent:(NSString *)content
{
    MBServiceFile *serviceFile = [[self alloc] init];
    if (![serviceFile parseContent:content]) {
        [serviceFile release];
        return nil;
    }
    return serviceFile;
}

- (BOOL)parseContent:(NSString *)content
{
    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL inServiceSection = NO;
    
    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // Skip empty lines and comments
        if ([trimmedLine length] == 0 || [trimmedLine hasPrefix:@"#"]) {
            continue;
        }
        
        // Check for section header
        if ([trimmedLine hasPrefix:@"["] && [trimmedLine hasSuffix:@"]"]) {
            NSString *sectionName = [trimmedLine substringWithRange:NSMakeRange(1, [trimmedLine length] - 2)];
            inServiceSection = [sectionName isEqualToString:@"D-BUS Service"];
            continue;
        }
        
        // Parse key=value pairs in service section
        if (inServiceSection) {
            NSRange equalRange = [trimmedLine rangeOfString:@"="];
            if (equalRange.location != NSNotFound) {
                NSString *key = [[trimmedLine substringToIndex:equalRange.location] 
                                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString *value = [[trimmedLine substringFromIndex:equalRange.location + 1] 
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                
                if ([key isEqualToString:@"Name"]) {
                    _serviceName = [value copy];
                } else if ([key isEqualToString:@"Exec"]) {
                    _executablePath = [value copy];
                } else if ([key isEqualToString:@"User"]) {
                    _user = [value copy];
                } else if ([key isEqualToString:@"SystemdService"]) {
                    _systemdService = [value copy];
                } else if ([key isEqualToString:@"AssumedAppArmorLabel"]) {
                    _assumedAppArmorLabel = [value copy];
                }
            }
        }
    }
    
    return [self isValid];
}

- (BOOL)isValid
{
    // Service name and executable are required
    return _serviceName != nil && [_serviceName length] > 0 &&
           _executablePath != nil && [_executablePath length] > 0;
}

- (NSArray *)commandLineArguments
{
    if (!_executablePath) {
        return @[];
    }
    
    // Simple shell-style argument parsing
    // This is a basic implementation - a full implementation would handle quotes, escapes etc.
    NSMutableArray *arguments = [NSMutableArray array];
    NSArray *components = [_executablePath componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    
    for (NSString *component in components) {
        NSString *trimmed = [component stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed length] > 0) {
            [arguments addObject:trimmed];
        }
    }
    
    return arguments;
}

- (void)dealloc
{
    [_serviceName release];
    [_executablePath release];
    [_user release];
    [_systemdService release];
    [_assumedAppArmorLabel release];
    [super dealloc];
}

@end
