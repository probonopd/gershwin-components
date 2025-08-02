#import "MBServiceManager.h"
#import "MBServiceFile.h"
#import <sys/wait.h>
#import <unistd.h>

@implementation MBServiceManager

- (instancetype)initWithServicePaths:(NSArray *)servicePaths
{
    self = [super init];
    if (self) {
        _services = [[NSMutableDictionary alloc] init];
        _activatingServices = [[NSMutableDictionary alloc] init];
        _servicePaths = [servicePaths copy];
    }
    return self;
}

- (void)dealloc
{
    [_services release];
    [_activatingServices release];
    [_servicePaths release];
    [super dealloc];
}

- (void)loadServices
{
    [_services removeAllObjects];
    
    for (NSString *servicePath in _servicePaths) {
        [self loadServicesFromDirectory:servicePath];
    }
    
    NSLog(@"Loaded %lu D-Bus services from %lu directories", 
          (unsigned long)[_services count], (unsigned long)[_servicePaths count]);
}

- (void)loadServicesFromDirectory:(NSString *)directory
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    
    NSArray *files = [fileManager contentsOfDirectoryAtPath:directory error:&error];
    if (!files) {
        NSLog(@"Could not read service directory %@: %@", directory, error.localizedDescription);
        return;
    }
    
    NSLog(@"Scanning service directory: %@", directory);
    
    for (NSString *filename in files) {
        if (![filename hasSuffix:@".service"]) {
            continue;
        }
        
        NSString *fullPath = [directory stringByAppendingPathComponent:filename];
        MBServiceFile *serviceFile = [MBServiceFile serviceFileFromPath:fullPath];
        
        if (serviceFile && [serviceFile isValid]) {
            NSLog(@"Loaded service: %@ -> %@", serviceFile.serviceName, serviceFile.executablePath);
            [_services setObject:serviceFile forKey:serviceFile.serviceName];
        } else {
            NSLog(@"Invalid service file: %@", fullPath);
        }
    }
}

- (BOOL)hasService:(NSString *)serviceName
{
    return [_services objectForKey:serviceName] != nil;
}

- (MBServiceFile *)serviceFileForName:(NSString *)serviceName
{
    return [_services objectForKey:serviceName];
}

- (BOOL)activateService:(NSString *)serviceName 
            busAddress:(NSString *)busAddress
                busType:(NSString *)busType
                  error:(NSError **)error
{
    MBServiceFile *serviceFile = [_services objectForKey:serviceName];
    if (!serviceFile) {
        if (error) {
            *error = [NSError errorWithDomain:@"MBServiceManager" 
                                         code:1 
                                     userInfo:@{NSLocalizedDescriptionKey: 
                                               [NSString stringWithFormat:@"Service %@ not found", serviceName]}];
        }
        return NO;
    }
    
    // Check if already activating
    if ([_activatingServices objectForKey:serviceName]) {
        NSLog(@"Service %@ is already being activated", serviceName);
        return YES; // Consider this success - activation is in progress
    }
    
    NSLog(@"Activating service: %@ (exec: %@)", serviceName, serviceFile.executablePath);
    
    // Mark as activating
    [_activatingServices setObject:[NSDate date] forKey:serviceName];
    
    // Get command line arguments
    NSArray *arguments = [serviceFile commandLineArguments];
    if ([arguments count] == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MBServiceManager" 
                                         code:2 
                                     userInfo:@{NSLocalizedDescriptionKey: 
                                               @"No executable specified in service file"}];
        }
        [_activatingServices removeObjectForKey:serviceName];
        return NO;
    }
    
    NSString *executable = [arguments objectAtIndex:0];
    NSArray *execArgs = [arguments count] > 1 ? [arguments subarrayWithRange:NSMakeRange(1, [arguments count] - 1)] : @[];
    
    // Check if executable exists and is executable
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager isExecutableFileAtPath:executable]) {
        NSLog(@"Executable not found or not executable: %@", executable);
        if (error) {
            *error = [NSError errorWithDomain:@"MBServiceManager" 
                                         code:3 
                                     userInfo:@{NSLocalizedDescriptionKey: 
                                               [NSString stringWithFormat:@"Executable not found: %@", executable]}];
        }
        [_activatingServices removeObjectForKey:serviceName];
        return NO;
    }
    
    // Fork and exec the service
    pid_t pid = fork();
    
    if (pid == -1) {
        // Fork failed
        NSLog(@"Failed to fork for service activation: %s", strerror(errno));
        if (error) {
            *error = [NSError errorWithDomain:@"MBServiceManager" 
                                         code:4 
                                     userInfo:@{NSLocalizedDescriptionKey: 
                                               [NSString stringWithFormat:@"Fork failed: %s", strerror(errno)]}];
        }
        [_activatingServices removeObjectForKey:serviceName];
        return NO;
    }
    
    if (pid == 0) {
        // Child process - set up environment and exec
        
        // Set D-Bus environment variables (required by D-Bus specification)
        if (busAddress) {
            setenv("DBUS_STARTER_ADDRESS", [busAddress UTF8String], 1);
            // Also set the session bus address so the service knows where to connect
            setenv("DBUS_SESSION_BUS_ADDRESS", [busAddress UTF8String], 1);
        }
        if (busType) {
            setenv("DBUS_STARTER_BUS_TYPE", [busType UTF8String], 1);
        }
        
        // Additional helpful environment variables for services
        setenv("DBUS_ACTIVATION", "1", 1);  // Indicate this is an activated service
        
        // Clear any potentially conflicting D-Bus environment variables
        unsetenv("DBUS_SYSTEM_BUS_ADDRESS");
        
        // Preserve all environment variables
        extern char **environ;
        for (char **env = environ; *env != NULL; env++) {
            char *entry = strdup(*env);
            if (!entry) continue;
            char *eq = strchr(entry, '=');
            if (eq) {
            *eq = '\0';
            setenv(entry, eq + 1, 1);
            }
            free(entry);
        }
        
        // Prepare arguments for execv
        int argc = 1 + [execArgs count];
        char **argv = malloc((argc + 1) * sizeof(char *));
        
        argv[0] = strdup([executable UTF8String]);
        for (int i = 0; i < [execArgs count]; i++) {
            argv[i + 1] = strdup([[execArgs objectAtIndex:i] UTF8String]);
        }
        argv[argc] = NULL;
        
        // Execute the service
        execv([executable UTF8String], argv);
        
        // If we get here, exec failed
        perror("execv failed");
        exit(1);
    } else {
        // Parent process - service activation started
        NSLog(@"Started service %@ with PID %d", serviceName, pid);
        
        // We don't wait for the child here - it should connect to the bus independently
        // The daemon will detect when the service connects and mark activation as complete
        
        return YES;
    }
}

- (BOOL)isActivatingService:(NSString *)serviceName
{
    NSDate *activationStart = [_activatingServices objectForKey:serviceName];
    if (!activationStart) {
        return NO;
    }
    
    // Check if activation has been going on too long (timeout after 30 seconds)
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:activationStart];
    if (elapsed > 30.0) {
        NSLog(@"Service activation timeout for %@ (%.1f seconds)", serviceName, elapsed);
        [_activatingServices removeObjectForKey:serviceName];
        return NO;
    }
    
    return YES;
}

- (void)serviceActivationCompleted:(NSString *)serviceName
{
    NSDate *activationStart = [_activatingServices objectForKey:serviceName];
    if (activationStart) {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:activationStart];
        NSLog(@"Service activation completed for %@ (%.3f seconds)", serviceName, elapsed);
        [_activatingServices removeObjectForKey:serviceName];
    }
}

- (NSArray *)availableServiceNames
{
    return [_services allKeys];
}

@end
