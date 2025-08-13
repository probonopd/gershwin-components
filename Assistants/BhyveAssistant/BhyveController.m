//
// BhyveController.m
// Bhyve Assistant - Main Controller
//

#import "BhyveController.h"
#import "BhyveISOSelectionStep.h"
#import "BhyveConfigurationStep.h"
#import "BhyveRunningStep.h"

@interface BhyveController()
@property (nonatomic, strong) BhyveISOSelectionStep *isoSelectionStep;
@property (nonatomic, strong) BhyveConfigurationStep *configurationStep;
@property (nonatomic, strong) BhyveRunningStep *runningStep;
@end

@implementation BhyveController

@synthesize selectedISOPath = _selectedISOPath;
@synthesize selectedISOName = _selectedISOName;
@synthesize selectedISOSize = _selectedISOSize;
@synthesize vmName = _vmName;
@synthesize allocatedRAM = _allocatedRAM;
@synthesize allocatedCPUs = _allocatedCPUs;
@synthesize diskSize = _diskSize;
@synthesize enableVNC = _enableVNC;
@synthesize vncPort = _vncPort;
@synthesize networkMode = _networkMode;
@synthesize bootMode = _bootMode;
@synthesize vmRunning = _vmRunning;

- (id)init
{
    if (self = [super init]) {
        NSLog(@"BhyveController: init");
        _selectedISOPath = @"";
        _selectedISOName = @"";
        _selectedISOSize = 0;
        _vmName = @"FreeBSD-Live";
        _allocatedRAM = 2048; // 2GB default
        _allocatedCPUs = 2;
        _diskSize = 20; // 20GB default
        _enableVNC = YES;
        _vncPort = 5900;
        _networkMode = @"bridge";
        _bootMode = @"bios";
        _vmRunning = NO;
        _bhyveTask = nil;
        _vncViewerTask = nil;
        _logWindow = nil;
        _logTextView = nil;
        _logFileHandle = nil;
        _vmLogBuffer = [[NSMutableString alloc] init];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"BhyveController: dealloc");
    [self stopVirtualMachine];
    [self cleanupTemporaryFiles];
    [self closeLogWindow];
    [_assistantWindow release];
    [_selectedISOPath release];
    [_selectedISOName release];
    [_vmName release];
    [_networkMode release];
    [_bootMode release];
    [_vmLogBuffer release];
    [super dealloc];
}

- (void)showAssistant
{
    NSLog(@"BhyveController: showAssistant");
    
    // Check system requirements FIRST
    NSString *errorMessage = [self checkSystemRequirements];
    if (errorMessage) {
        // Show error immediately and don't build the normal assistant
        [self showSystemRequirementsError:errorMessage];
        return;
    }
    
    // Create step views
    _isoSelectionStep = [[BhyveISOSelectionStep alloc] init];
    [_isoSelectionStep setController:self];
    _configurationStep = [[BhyveConfigurationStep alloc] init];
    [_configurationStep setController:self];
    _runningStep = [[BhyveRunningStep alloc] init];
    [_runningStep setController:self];
    
    // Build the assistant using the builder
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    [builder withLayoutStyle:GSAssistantLayoutStyleInstaller];
    [builder withTitle:NSLocalizedString(@"Bhyve Virtual Machine", @"Application title")];
    [builder withIcon:[NSImage imageNamed:@"Bhyve_VM"]];
    
    // Add configuration steps directly
    [builder addStep:_isoSelectionStep];
    [builder addStep:_configurationStep];
    [builder addStep:_runningStep];
    
    // Build and show
    _assistantWindow = [builder build];
    [_assistantWindow setDelegate:self];
    [[_assistantWindow window] makeKeyAndOrderFront:nil];
}

#pragma mark - Helper Methods

- (NSString *)checkSystemRequirements
{
    NSLog(@"BhyveController: checkSystemRequirements");
    
    // Check if we're on FreeBSD first
    NSTask *unameTask = [[NSTask alloc] init];
    [unameTask setLaunchPath:@"/usr/bin/uname"];
    [unameTask setArguments:@[@"-s"]];
    
    NSPipe *unamePipe = [NSPipe pipe];
    [unameTask setStandardOutput:unamePipe];
    
    @try {
        [unameTask launch];
        [unameTask waitUntilExit];
        
        NSData *data = [[unamePipe fileHandleForReading] readDataToEndOfFile];
        NSString *osName = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        osName = [osName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        NSLog(@"BhyveController: Operating system: %@", osName);
        
        if (![osName isEqualToString:@"FreeBSD"]) {
            NSString *error = [NSString stringWithFormat:@"bhyve is only available on FreeBSD.\n\nCurrent operating system: %@\n\nThis assistant requires FreeBSD with bhyve support to create and run virtual machines.", osName];
            [osName release];
            [unameTask release];
            return error;
        }
        [osName release];
        [unameTask release];
    } @catch (NSException *exception) {
        NSLog(@"BhyveController: Error checking OS: %@", [exception reason]);
        [unameTask release];
        return @"Unable to determine the operating system.\n\nThis assistant requires FreeBSD with bhyve support.";
    }
    
    // Check if bhyve is available
    if (![self checkBhyveAvailable]) {
        return @"bhyve is not available on this system.\n\nPlease ensure that:\n• bhyve is installed (pkg install bhyve-firmware)\n• The vmm kernel module is loaded\n• You have root privileges\n• Hardware virtualization is enabled in BIOS\n\nFor more information, see the FreeBSD Handbook chapter on bhyve.";
    }
    
    // Test bhyve basic functionality
    if (![self testBhyveBasicFunction]) {
        return @"bhyve permission test failed.\n\nThis usually indicates:\n• Insufficient privileges (not running as root)\n• Hardware virtualization not enabled in BIOS\n• Conflicting hypervisor software running\n• VMM kernel module issues\n\nPlease run the assistant with 'sudo -A -E' and ensure hardware virtualization is enabled.";
    }
    
    // Check if UEFI firmware is available (required for most ISOs)
    NSArray *uefiPaths = @[
        @"/usr/local/share/uefi-firmware/BHYVE_UEFI.fd",
        @"/usr/local/share/edk2-bhyve/BHYVE_UEFI.fd",
        @"/usr/local/share/bhyve/BHYVE_UEFI.fd"
    ];
    
    BOOL uefiFound = NO;
    for (NSString *path in uefiPaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            uefiFound = YES;
            break;
        }
    }
    
    if (!uefiFound) {
        return @"UEFI firmware not found.\n\nMost modern ISOs (including GhostBSD and Linux) require UEFI firmware to boot in bhyve.\n\nPlease install the firmware:\n\nsudo pkg install bhyve-firmware\n\nThis will install the necessary UEFI boot ROM files.";
    }
    
    NSLog(@"BhyveController: All system requirements met");
    return nil; // No error
}

- (void)showSystemRequirementsError:(NSString *)message
{
    NSLog(@"BhyveController: showSystemRequirementsError: %@", message);
    
    // Create a minimal assistant builder just to show the error page
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    [builder withLayoutStyle:GSAssistantLayoutStyleInstaller];
    [builder withTitle:NSLocalizedString(@"Bhyve Virtual Machine", @"Application title")];
    [builder withIcon:[NSImage imageNamed:@"Bhyve_VM"]];
    
    // Build the assistant window but don't add any steps
    _assistantWindow = [builder build];
    [_assistantWindow setDelegate:self];
    
    // Show the window first
    [[_assistantWindow window] makeKeyAndOrderFront:nil];
    
    // Then immediately show the error page
    if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithTitle:message:)]) {
        NSLog(@"BhyveController: calling showErrorPageWithTitle:message:");
        [_assistantWindow showErrorPageWithTitle:@"System Requirements Not Met" message:message];
    } else if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithMessage:)]) {
        NSLog(@"BhyveController: calling showErrorPageWithMessage:");
        [_assistantWindow showErrorPageWithMessage:message];
    } else {
        NSLog(@"BhyveController: assistant window doesn't respond to error page methods");
        // Fallback - just log the error
        NSLog(@"BhyveController: System requirements error: %@", message);
    }
}

- (BOOL)checkBhyveAvailable
{
    NSLog(@"BhyveController: checkBhyveAvailable");
    
    // Check if bhyve command exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/bhyve"]) {
        NSLog(@"BhyveController: bhyve binary not found at /usr/sbin/bhyve");
        return NO;
    }
    
    // Check if bhyvectl exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/bhyvectl"]) {
        NSLog(@"BhyveController: bhyvectl binary not found at /usr/sbin/bhyvectl");
        return NO;
    }
    
    NSLog(@"BhyveController: bhyve tools available");
    return YES;
}

- (BOOL)checkVNCClientAvailable
{
    NSLog(@"BhyveController: checkVNCClientAvailable");
    
    // Check common VNC viewer paths
    NSArray *vncViewers = @[@"/usr/local/bin/vncviewer", @"/usr/bin/vncviewer", @"vncviewer"];
    
    for (NSString *vncPath in vncViewers) {
        if ([vncPath hasPrefix:@"/"]) {
            // Absolute path check
            if ([[NSFileManager defaultManager] fileExistsAtPath:vncPath]) {
                NSLog(@"BhyveController: Found VNC viewer at %@", vncPath);
                return YES;
            }
        } else {
            // Check if command is in PATH
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"/usr/bin/which"];
            [task setArguments:@[vncPath]];
            
            NSPipe *pipe = [NSPipe pipe];
            [task setStandardOutput:pipe];
            [task setStandardError:pipe];
            
            @try {
                [task launch];
                [task waitUntilExit];
                int exitStatus = [task terminationStatus];
                [task release];
                
                if (exitStatus == 0) {
                    NSLog(@"BhyveController: Found VNC viewer '%@' in PATH", vncPath);
                    return YES;
                }
            } @catch (NSException *exception) {
                NSLog(@"BhyveController: Error checking VNC client in PATH: %@", [exception reason]);
                [task release];
            }
        }
    }
    
    NSLog(@"BhyveController: No VNC viewer found");
    return NO;
}

- (BOOL)validateVMConfiguration
{
    NSLog(@"BhyveController: validateVMConfiguration");
    
    // Check if ISO is selected
    if (!_selectedISOPath || [_selectedISOPath length] == 0) {
        NSLog(@"BhyveController: No ISO selected");
        return NO;
    }
    
    // Check if ISO file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:_selectedISOPath]) {
        NSLog(@"BhyveController: ISO file does not exist: %@", _selectedISOPath);
        return NO;
    }
    
    // Check VM name
    if (!_vmName || [_vmName length] == 0) {
        NSLog(@"BhyveController: No VM name specified");
        return NO;
    }
    
    // Check memory allocation (minimum 512MB)
    if (_allocatedRAM < 512) {
        NSLog(@"BhyveController: Insufficient RAM allocated: %ld MB", (long)_allocatedRAM);
        return NO;
    }
    
    // Check CPU allocation (minimum 1)
    if (_allocatedCPUs < 1) {
        NSLog(@"BhyveController: Invalid CPU count: %ld", (long)_allocatedCPUs);
        return NO;
    }
    
    // Check if bhyve command exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/bhyve"]) {
        NSLog(@"BhyveController: bhyve command not found");
        return NO;
    }
    
    // Check if bhyvectl command exists  
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/bhyvectl"]) {
        NSLog(@"BhyveController: bhyvectl command not found");
        return NO;
    }
    
    // Check if running as root (bhyve typically requires root privileges)
    if (getuid() != 0) {
        NSLog(@"BhyveController: ERROR - Not running as root, bhyve will fail");
        return NO; // Fail validation if not root
    } else {
        NSLog(@"BhyveController: Running as root - good");
    }
    
    // Check if vmm kernel module is available
    NSTask *kldstatTask = [[NSTask alloc] init];
    [kldstatTask setLaunchPath:@"/sbin/kldstat"];
    [kldstatTask setArguments:@[@"-q", @"-m", @"vmm"]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    [kldstatTask setStandardOutput:outputPipe];
    [kldstatTask setStandardError:outputPipe];
    
    @try {
        [kldstatTask launch];
        [kldstatTask waitUntilExit];
        int kldstatStatus = [kldstatTask terminationStatus];
        [kldstatTask release];
        
        if (kldstatStatus != 0) {
            NSLog(@"BhyveController: vmm kernel module not loaded, will attempt to load");
        } else {
            NSLog(@"BhyveController: vmm kernel module is loaded");
        }
    } @catch (NSException *exception) {
        NSLog(@"BhyveController: Error checking vmm module: %@", [exception reason]);
        [kldstatTask release];
        // Continue anyway
    }
    
    // Check hardware virtualization support
    NSTask *hwVirtTask = [[NSTask alloc] init];
    [hwVirtTask setLaunchPath:@"/sbin/sysctl"];
    [hwVirtTask setArguments:@[@"-n", @"hw.vmm.vmx.initialized"]];
    
    NSPipe *hwVirtPipe = [NSPipe pipe];
    [hwVirtTask setStandardOutput:hwVirtPipe];
    [hwVirtTask setStandardError:hwVirtPipe];
    
    @try {
        [hwVirtTask launch];
        [hwVirtTask waitUntilExit];
        int hwVirtStatus = [hwVirtTask terminationStatus];
        
        if (hwVirtStatus == 0) {
            NSData *data = [[hwVirtPipe fileHandleForReading] readDataToEndOfFile];
            NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            if ([result isEqualToString:@"1"]) {
                NSLog(@"BhyveController: Hardware virtualization (VMX) is enabled");
            } else {
                NSLog(@"BhyveController: WARNING - Hardware virtualization (VMX) may not be enabled");
            }
            [result release];
        } else {
            NSLog(@"BhyveController: Could not check hardware virtualization status");
        }
        [hwVirtTask release];
    } @catch (NSException *exception) {
        NSLog(@"BhyveController: Error checking hardware virtualization: %@", [exception reason]);
        [hwVirtTask release];
    }
    
    return YES;
}

- (NSString *)generateVMCommand
{
    NSLog(@"BhyveController: generateVMCommand");
    
    NSMutableString *command = [NSMutableString string];
    
    // First, destroy any existing VM instance
    [command appendFormat:@"bhyvectl --destroy --vm=\"%@\" 2>/dev/null || true; ", _vmName];
    
    // For UEFI mode, we need different setup
    if ([_bootMode isEqualToString:@"uefi"]) {
        // UEFI requires specific configuration
        [command appendString:@"bhyve -A -H -P -w"];
        
        // Memory
        [command appendFormat:@" -m %ldM", (long)_allocatedRAM];
        
        // CPUs
        [command appendFormat:@" -c %ld", (long)_allocatedCPUs];
        
        // PCI slots
        [command appendString:@" -s 0:0,hostbridge"];
        [command appendString:@" -s 31,lpc"];
        
        // CDROM (ISO) - Use ahci-cd for UEFI
        [command appendFormat:@" -s 2:0,ahci-cd,\"%@\"", _selectedISOPath];
        
        // Virtual disk
        NSString *diskPath = [NSString stringWithFormat:@"/tmp/%@.img", _vmName];
        [command appendFormat:@" -s 3:0,virtio-blk,\"%@\"", diskPath];
        
        // Network - only add if network interfaces are available
        if ([_networkMode isEqualToString:@"bridge"] || [_networkMode isEqualToString:@"nat"]) {
            // For now, skip networking to avoid interface issues
            // [command appendString:@" -s 4:0,virtio-net"];
            NSLog(@"BhyveController: Skipping network configuration to avoid interface issues");
        }
        // Skip network entirely for "none" mode
        
        // VNC - Use enhanced framebuffer device configuration
        if (_enableVNC) {
            [command appendString:[self generateVNCFramebufferConfig]];
        }
        
        // Console output
        [command appendString:@" -l com1,stdio"];
        
        // UEFI firmware - check multiple possible paths
        NSArray *uefiPaths = @[
            @"/usr/local/share/uefi-firmware/BHYVE_UEFI.fd",
            @"/usr/local/share/bhyve/BHYVE_UEFI.fd",
            @"/usr/share/bhyve/BHYVE_UEFI.fd",
            @"/boot/firmware/BHYVE_UEFI.fd"
        ];
        
        NSString *uefiPath = nil;
        for (NSString *path in uefiPaths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                uefiPath = path;
                break;
            }
        }
        
        if (uefiPath) {
            [command appendFormat:@" -l bootrom,\"%@\"", uefiPath];
            NSLog(@"BhyveController: Using UEFI firmware: %@", uefiPath);
        } else {
            NSLog(@"BhyveController: WARNING - UEFI firmware not found in standard locations");
            // Continue anyway - bhyve might have a default
        }
        
        // VM name (must be last)
        [command appendFormat:@" \"%@\"", _vmName];
    } else {
        // BIOS mode - use simpler configuration that works with most ISOs
        [command appendString:@"bhyve -A -H -P"];
        
        // Memory
        [command appendFormat:@" -m %ldM", (long)_allocatedRAM];
        
        // CPUs 
        [command appendFormat:@" -c %ld", (long)_allocatedCPUs];
        
        // PCI slots
        [command appendString:@" -s 0:0,hostbridge"];
        [command appendString:@" -s 31,lpc"];
        
        // CDROM (ISO) as primary boot device - Use ahci-cd which supports boot
        [command appendFormat:@" -s 2:0,ahci-cd,\"%@\"", _selectedISOPath];
        
        // Virtual disk as secondary
        NSString *diskPath = [NSString stringWithFormat:@"/tmp/%@.img", _vmName];
        [command appendFormat:@" -s 3:0,virtio-blk,\"%@\"", diskPath];
        
        // Network - only add if network mode is not "none"
        if ([_networkMode isEqualToString:@"bridge"] || [_networkMode isEqualToString:@"nat"]) {
            // For now, skip networking to avoid interface issues
            // [command appendString:@" -s 4:0,virtio-net"];
            NSLog(@"BhyveController: Skipping network configuration to avoid interface issues");
        }
        
        // VNC - Use enhanced framebuffer device configuration
        if (_enableVNC) {
            [command appendString:[self generateVNCFramebufferConfig]];
        }
        
        // Console output to stdio
        [command appendString:@" -l com1,stdio"];
        
        // Both BIOS and modern ISOs need UEFI firmware to boot properly
        // Check multiple possible paths for UEFI firmware
        NSArray *uefiPaths = @[
            @"/usr/local/share/uefi-firmware/BHYVE_UEFI.fd",
            @"/usr/local/share/edk2-bhyve/BHYVE_UEFI.fd",
            @"/usr/local/share/bhyve/BHYVE_UEFI.fd",
            @"/usr/share/bhyve/BHYVE_UEFI.fd",
            @"/boot/firmware/BHYVE_UEFI.fd"
        ];
        
        NSString *uefiPath = nil;
        for (NSString *path in uefiPaths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                uefiPath = path;
                break;
            }
        }
        
        if (uefiPath) {
            [command appendFormat:@" -l bootrom,\"%@\"", uefiPath];
            NSLog(@"BhyveController: Using UEFI firmware: %@", uefiPath);
        } else {
            NSLog(@"BhyveController: WARNING - UEFI firmware not found, VM may not boot properly");
            NSLog(@"BhyveController: Install with: pkg install bhyve-firmware");
        }
        
        // VM name (must be last)
        [command appendFormat:@" \"%@\"", _vmName];
    }
    
    NSLog(@"BhyveController: Generated VM command: %@", command);
    return [NSString stringWithString:command];
}

- (BOOL)createVirtualDisk
{
    NSLog(@"BhyveController: createVirtualDisk");
    
    NSString *diskPath = [NSString stringWithFormat:@"/tmp/%@.img", _vmName];
    
    // Check if disk already exists
    if ([[NSFileManager defaultManager] fileExistsAtPath:diskPath]) {
        NSLog(@"BhyveController: Virtual disk already exists at %@", diskPath);
        return YES;
    }
    
    // Create sparse disk image using truncate
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/truncate"];
    [task setArguments:@[@"-s", [NSString stringWithFormat:@"%ldG", (long)_diskSize], diskPath]];
    
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        int exitStatus = [task terminationStatus];
        
        if (exitStatus != 0) {
            NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
            NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSLog(@"BhyveController: Failed to create virtual disk (exit code %d): %@", exitStatus, errorOutput);
            [errorOutput release];
            [task release];
            return NO;
        } else {
            NSLog(@"BhyveController: Created virtual disk at %@ (%ld GB)", diskPath, (long)_diskSize);
            [task release];
            return YES;
        }
    } @catch (NSException *exception) {
        NSLog(@"BhyveController: Error creating virtual disk: %@", [exception reason]);
        [task release];
        return NO;
    }
}

#pragma mark - VM Management

- (void)startVirtualMachine
{
    NSLog(@"BhyveController: startVirtualMachine");
    
    if (_vmRunning) {
        NSLog(@"BhyveController: VM is already running");
        return;
    }
    
    if (![self validateVMConfiguration]) {
        [self showVMError:@"Invalid VM configuration"];
        return;
    }
    
    // Create virtual disk
    if (![self createVirtualDisk]) {
        [self showVMError:@"Failed to create virtual disk"];
        return;
    }
    
    // Generate VM command
    NSString *command = [self generateVMCommand];
    NSLog(@"BhyveController: VM command: %@", command);
    
    // Load bhyve kernel module if needed
    NSTask *kldloadTask = [[NSTask alloc] init];
    [kldloadTask setLaunchPath:@"/sbin/kldload"];
    [kldloadTask setArguments:@[@"vmm"]];
    
    @try {
        [kldloadTask launch];
        [kldloadTask waitUntilExit];
        int kldloadStatus = [kldloadTask terminationStatus];
        if (kldloadStatus == 0) {
            NSLog(@"BhyveController: vmm module loaded successfully");
        } else {
            NSLog(@"BhyveController: vmm module load failed (exit code %d) - may already be loaded", kldloadStatus);
        }
        [kldloadTask release];
    } @catch (NSException *exception) {
        NSLog(@"BhyveController: Error loading vmm module: %@", [exception reason]);
        [kldloadTask release];
        // Continue anyway - module might already be loaded
    }
    
    // Start bhyve VM in background
    _bhyveTask = [[NSTask alloc] init];
    [_bhyveTask setLaunchPath:@"/bin/sh"];
    [_bhyveTask setArguments:@[@"-c", command]];
    
    // Set up pipes for output
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [_bhyveTask setStandardOutput:outputPipe];
    [_bhyveTask setStandardError:errorPipe];
    
    NSLog(@"BhyveController: About to launch bhyve command: %@", command);
    
    @try {
        [_bhyveTask launch];
        
        NSLog(@"BhyveController: bhyve task launched with PID %d", [_bhyveTask processIdentifier]);
        
        // Wait a moment to see if the process starts successfully
        [NSThread sleepForTimeInterval:1.0];
        
        if ([_bhyveTask isRunning]) {
            _vmRunning = YES;
            [self showVMStatus:[NSString stringWithFormat:@"Virtual Machine '%@' started successfully (PID: %d)", _vmName, [_bhyveTask processIdentifier]]];
            
            // Initialize log with startup message
            NSString *startupLog = [NSString stringWithFormat:@"=== VM '%@' Started ===\nPID: %d\nCommand: %@\n\n", 
                                   _vmName, [_bhyveTask processIdentifier], command];
            [self updateVMLog:startupLog];
            
            // Set up continuous log monitoring in background
            [NSThread detachNewThreadSelector:@selector(monitorVMOutput:) 
                                      toTarget:self 
                                    withObject:@[outputPipe, errorPipe]];
            
            // Start VNC viewer if enabled
            if (_enableVNC) {
                [self performSelector:@selector(startVNCViewer) withObject:nil afterDelay:2.0];
            }
            
            NSLog(@"BhyveController: VM running with PID %d", [_bhyveTask processIdentifier]);
        } else {
            // Process died immediately - check error output
            NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
            NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            
            NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSString *stdOutput = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
            int exitStatus = [_bhyveTask terminationStatus];
            
            // Combine output and error, look for exit_reason
            NSMutableString *fullOutput = [NSMutableString string];
            if (stdOutput && [stdOutput length] > 0) {
                [fullOutput appendString:stdOutput];
            }
            if (errorOutput && [errorOutput length] > 0) {
                if ([fullOutput length] > 0) [fullOutput appendString:@"\n"];
                [fullOutput appendString:errorOutput];
            }
            
            // Look for specific bhyve error patterns
            NSString *exitReason = nil;
            NSMutableString *errorMessage = [NSMutableString string];
            
            if ([fullOutput containsString:@"Operation not permitted"]) {
                [errorMessage appendString:@"bhyve Permission Error\n\n"];
                [errorMessage appendString:@"bhyve requires root privileges and proper system configuration. "];
                [errorMessage appendString:@"Please ensure:\n"];
                [errorMessage appendString:@"• Running as root (use sudo)\n"];
                [errorMessage appendString:@"• VMM kernel module is loaded\n"];
                [errorMessage appendString:@"• Hardware virtualization is enabled in BIOS\n"];
                [errorMessage appendString:@"• No conflicting hypervisors are running\n\n"];
            } else if ([fullOutput containsString:@"Usage: bhyve"]) {
                [errorMessage appendString:@"bhyve Command Syntax Error\n\n"];
                [errorMessage appendString:@"The bhyve command has invalid syntax. This is likely "];
                [errorMessage appendString:@"a configuration issue in the BhyveAssistant.\n\n"];
            } else if ([fullOutput containsString:@"exit_reason"]) {
                NSArray *lines = [fullOutput componentsSeparatedByString:@"\n"];
                for (NSString *line in lines) {
                    if ([line containsString:@"exit_reason"]) {
                        exitReason = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        break;
                    }
                }
                [errorMessage appendFormat:@"bhyve VM Exit\n\n%@\n\n", exitReason];
            } else {
                [errorMessage appendFormat:@"VM failed to start (exit code %d)\n\n", exitStatus];
            }
            
            if ([fullOutput length] > 0) {
                [errorMessage appendFormat:@"Full Output:\n%@", fullOutput];
            } else {
                [errorMessage appendString:@"No output captured from bhyve process."];
            }
            
            NSLog(@"BhyveController: VM process died immediately (exit code %d): %@", exitStatus, fullOutput);
            [self showVMError:[NSString stringWithString:errorMessage]];
            
            [errorOutput release];
            [stdOutput release];
            _vmRunning = NO;
            [_bhyveTask release];
            _bhyveTask = nil;
        }
        
    } @catch (NSException *exception) {
        NSLog(@"BhyveController: Error starting VM: %@", [exception reason]);
        [self showVMError:[NSString stringWithFormat:@"Failed to start VM: %@", [exception reason]]];
        _vmRunning = NO;
        [_bhyveTask release];
        _bhyveTask = nil;
    }
}

- (void)startVNCViewer
{
    NSLog(@"BhyveController: startVNCViewer");
    
    // Check if VNC client is available first
    if (![self checkVNCClientAvailable]) {
        [self showVMError:@"No VNC client found in PATH. Please install a VNC viewer (vncviewer) to access the virtual machine display."];
        return;
    }
    
    // Calculate display number (VNC display = port - 5900)
    NSInteger displayNumber = _vncPort - 5900;
    
    // Different address formats that VNC clients might expect
    NSArray *addressFormats = @[
        [NSString stringWithFormat:@"localhost:%ld", (long)_vncPort],              // Full port format
        [NSString stringWithFormat:@"localhost:%ld", (long)displayNumber],         // Display number format  
        [NSString stringWithFormat:@":%ld", (long)displayNumber],                  // Short display format
        [NSString stringWithFormat:@"localhost::%ld", (long)_vncPort],             // Double colon format
        [NSString stringWithFormat:@"127.0.0.1:%ld", (long)_vncPort]               // IP address format
    ];
    
    // Try different VNC viewers with different address formats
    NSArray *vncViewers = @[
        @"/usr/local/bin/vncviewer",    // TigerVNC, TightVNC
        @"/usr/bin/vncviewer",          // System VNC viewer
        @"/usr/local/bin/tigervnc-viewer", // TigerVNC alternative name
        @"/usr/local/bin/tightvnc-viewer", // TightVNC alternative name
        @"vncviewer",                   // Any vncviewer in PATH
        @"tigervnc-viewer",             // TigerVNC in PATH
        @"tightvnc-viewer"              // TightVNC in PATH
    ];
    
    for (NSString *vncPath in vncViewers) {
        BOOL vncExists = NO;
        
        if ([vncPath hasPrefix:@"/"]) {
            // Absolute path - check if file exists
            vncExists = [[NSFileManager defaultManager] fileExistsAtPath:vncPath];
        } else {
            // Check if command exists in PATH
            NSTask *whichTask = [[NSTask alloc] init];
            [whichTask setLaunchPath:@"/usr/bin/which"];
            [whichTask setArguments:@[vncPath]];
            [whichTask setStandardOutput:[NSPipe pipe]];
            [whichTask setStandardError:[NSPipe pipe]];
            
            @try {
                [whichTask launch];
                [whichTask waitUntilExit];
                vncExists = ([whichTask terminationStatus] == 0);
                [whichTask release];
            } @catch (NSException *exception) {
                [whichTask release];
                vncExists = NO;
            }
        }
        
        if (!vncExists) {
            continue; // Try next VNC viewer
        }
        
        NSLog(@"BhyveController: Found VNC viewer: %@", vncPath);
        
        // Try different address formats with this VNC viewer
        for (NSString *address in addressFormats) {
            NSLog(@"BhyveController: Trying VNC connection to %@", address);
            
            _vncViewerTask = [[NSTask alloc] init];
            
            if ([vncPath hasPrefix:@"/"]) {
                // Absolute path
                [_vncViewerTask setLaunchPath:vncPath];
                [_vncViewerTask setArguments:@[address]];
            } else {
                // Command in PATH
                [_vncViewerTask setLaunchPath:@"/usr/bin/env"];
                [_vncViewerTask setArguments:@[vncPath, address]];
            }
            
            // Redirect output to avoid terminal noise
            NSPipe *outputPipe = [NSPipe pipe];
            [_vncViewerTask setStandardOutput:outputPipe];
            [_vncViewerTask setStandardError:outputPipe];
            
            @try {
                [_vncViewerTask launch];
                
                // Give VNC viewer a moment to start
                [NSThread sleepForTimeInterval:0.5];
                
                if ([_vncViewerTask isRunning]) {
                    NSLog(@"BhyveController: VNC viewer started successfully with address %@", address);
                    [self showVMStatus:[NSString stringWithFormat:@"VNC viewer connected to %@", address]];
                    
                    // Show detailed VNC information and X11 troubleshooting tips
                    [self performSelector:@selector(showVNCConnectionInfo) withObject:nil afterDelay:1.0];
                    
                    return; // Success!
                } else {
                    // VNC viewer exited immediately, try next format
                    NSLog(@"BhyveController: VNC viewer exited immediately with address %@", address);
                    [_vncViewerTask release];
                    _vncViewerTask = nil;
                }
                
            } @catch (NSException *exception) {
                NSLog(@"BhyveController: Error starting VNC viewer with address %@: %@", address, [exception reason]);
                [_vncViewerTask release];
                _vncViewerTask = nil;
            }
        }
    }
    
    // If we get here, all attempts failed
    NSString *errorMsg = [NSString stringWithFormat:@"Failed to start VNC viewer.\n\nTried connecting to port %ld (display %ld).\n\nPlease ensure:\n• A VNC viewer is installed (vncviewer, tigervnc-viewer, etc.)\n• The virtual machine is running\n• VNC is enabled in VM configuration", (long)_vncPort, (long)displayNumber];
    [self showVMError:errorMsg];
}

- (void)stopVirtualMachine
{
    NSLog(@"BhyveController: stopVirtualMachine");
    
    if (!_vmRunning) {
        NSLog(@"BhyveController: VM is not running");
        return;
    }
    
    // Stop VNC viewer
    if (_vncViewerTask && [_vncViewerTask isRunning]) {
        [_vncViewerTask terminate];
        [_vncViewerTask release];
        _vncViewerTask = nil;
    }
    
    // Stop bhyve VM
    if (_bhyveTask && [_bhyveTask isRunning]) {
        [_bhyveTask terminate];
        [_bhyveTask waitUntilExit];
        [_bhyveTask release];
        _bhyveTask = nil;
    }
    
    // Destroy VM instance
    NSTask *destroyTask = [[NSTask alloc] init];
    [destroyTask setLaunchPath:@"/usr/sbin/bhyvectl"];
    [destroyTask setArguments:@[@"--destroy", [@"--vm=" stringByAppendingString:_vmName]]];
    
    @try {
        [destroyTask launch];
        [destroyTask waitUntilExit];
        [destroyTask release];
    } @catch (NSException *exception) {
        NSLog(@"BhyveController: Error destroying VM: %@", [exception reason]);
        [destroyTask release];
    }
    
    _vmRunning = NO;
    [self showVMStatus:@"Virtual Machine stopped"];
}

#pragma mark - Success and Error Handling

- (void)showVMStatus:(NSString *)message
{
    NSLog(@"BhyveController: showVMStatus: %@", message);
    
    // Update running step if available
    if (_runningStep) {
        [_runningStep updateStatus:message];
    }
}

- (void)showVMError:(NSString *)message
{
    NSLog(@"BhyveController: showVMError: %@", message);
    
    // Ensure we're on the main thread for UI updates
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(showVMError:) 
                               withObject:message 
                            waitUntilDone:NO];
        return;
    }
    
    // Use the framework's built-in error page method
    if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithTitle:message:)]) {
        [_assistantWindow showErrorPageWithTitle:@"Virtual Machine Error" message:message];
    } else if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithMessage:)]) {
        [_assistantWindow showErrorPageWithMessage:message];
    } else {
        NSLog(@"BhyveController: Error - assistant window doesn't support error pages");
    }
}

#pragma mark - Log Management

- (void)showVMLog
{
    NSLog(@"BhyveController: showVMLog");
    
    if (_logWindow) {
        // Window already exists, just bring it to front
        [_logWindow makeKeyAndOrderFront:nil];
        return;
    }
    
    // Create log window
    NSRect logFrame = NSMakeRect(100, 100, 600, 400);
    _logWindow = [[NSWindow alloc] initWithContentRect:logFrame
                                             styleMask:(NSWindowStyleMaskTitled | 
                                                       NSWindowStyleMaskClosable | 
                                                       NSWindowStyleMaskMiniaturizable | 
                                                       NSWindowStyleMaskResizable)
                                               backing:NSBackingStoreBuffered 
                                                 defer:NO];
    
    [_logWindow setTitle:[NSString stringWithFormat:@"VM Log - %@", _vmName]];
    [_logWindow setDelegate:self];
    
    // Create scroll view with text view
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:[[_logWindow contentView] bounds]];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:YES];
    [scrollView setAutohidesScrollers:NO];
    [scrollView setBorderType:NSNoBorder];
    [scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    
    // Create text view
    NSRect textFrame = [[scrollView contentView] bounds];
    _logTextView = [[NSTextView alloc] initWithFrame:textFrame];
    [_logTextView setMinSize:NSMakeSize(0.0, 0.0)];
    [_logTextView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
    [_logTextView setVerticallyResizable:YES];
    [_logTextView setHorizontallyResizable:NO];
    [_logTextView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [[_logTextView textContainer] setContainerSize:NSMakeSize(textFrame.size.width, CGFLOAT_MAX)];
    [[_logTextView textContainer] setWidthTracksTextView:YES];
    [_logTextView setEditable:NO];
    [_logTextView setSelectable:YES];
    [_logTextView setFont:[NSFont fontWithName:@"Monaco" size:10.0]];
    
    // Set up the text view in the scroll view
    [scrollView setDocumentView:_logTextView];
    [[_logWindow contentView] addSubview:scrollView];
    
    // Add any existing log content
    if ([_vmLogBuffer length] > 0) {
        [_logTextView setString:_vmLogBuffer];
        // Scroll to bottom
        [_logTextView scrollRangeToVisible:NSMakeRange([[_logTextView string] length], 0)];
    }
    
    [scrollView release];
    [_logWindow makeKeyAndOrderFront:nil];
}

- (void)updateVMLog:(NSString *)logText
{
    if (!logText || [logText length] == 0) return;
    
    // Add to buffer
    [_vmLogBuffer appendString:logText];
    
    // If log window is open, update it
    if (_logTextView) {
        [self performSelectorOnMainThread:@selector(updateLogTextView:) 
                               withObject:_vmLogBuffer 
                            waitUntilDone:NO];
    }
}

- (void)closeLogWindow
{
    NSLog(@"BhyveController: closeLogWindow");
    
    if (_logWindow) {
        [_logWindow close];
        [_logWindow release];
        _logWindow = nil;
    }
    
    if (_logTextView) {
        [_logTextView release];
        _logTextView = nil;
    }
    
    if (_logFileHandle) {
        [_logFileHandle closeFile];
        [_logFileHandle release];
        _logFileHandle = nil;
    }
}

- (void)updateLogTextView:(NSString *)logText
{
    if (_logTextView) {
        [_logTextView setString:logText];
        // Scroll to bottom
        [_logTextView scrollRangeToVisible:NSMakeRange([logText length], 0)];
    }
}

- (void)monitorVMOutput:(NSArray *)pipes
{
    NSLog(@"BhyveController: monitorVMOutput - starting background monitoring");
    
    NSPipe *outputPipe = [pipes objectAtIndex:0];
    NSPipe *errorPipe = [pipes objectAtIndex:1];
    
    NSFileHandle *outputHandle = [outputPipe fileHandleForReading];
    NSFileHandle *errorHandle = [errorPipe fileHandleForReading];
    
    // Monitor both output and error streams
    while (_vmRunning && _bhyveTask && [_bhyveTask isRunning]) {
        @autoreleasepool {
            // Check for output data
            NSData *outputData = [outputHandle availableData];
            if (outputData && [outputData length] > 0) {
                NSString *outputText = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
                if (outputText) {
                    [self updateVMLog:outputText];
                    [outputText release];
                }
            }
            
            // Check for error data
            NSData *errorData = [errorHandle availableData];
            if (errorData && [errorData length] > 0) {
                NSString *errorText = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
                if (errorText) {
                    NSString *prefixedError = [NSString stringWithFormat:@"[ERROR] %@", errorText];
                    [self updateVMLog:prefixedError];
                    [errorText release];
                }
            }
            
            // Small delay to avoid busy waiting
            [NSThread sleepForTimeInterval:0.1];
        }
    }
    
    // When VM stops, read any remaining output
    NSData *finalOutput = [outputHandle readDataToEndOfFile];
    if (finalOutput && [finalOutput length] > 0) {
        NSString *finalText = [[NSString alloc] initWithData:finalOutput encoding:NSUTF8StringEncoding];
        if (finalText) {
            [self updateVMLog:finalText];
            [finalText release];
        }
    }
    
    NSData *finalError = [errorHandle readDataToEndOfFile];
    if (finalError && [finalError length] > 0) {
        NSString *finalErrorText = [[NSString alloc] initWithData:finalError encoding:NSUTF8StringEncoding];
        if (finalErrorText) {
            NSString *prefixedFinalError = [NSString stringWithFormat:@"[ERROR] %@", finalErrorText];
            [self updateVMLog:prefixedFinalError];
            [finalErrorText release];
        }
    }
    
    [self updateVMLog:@"\n=== VM Process Terminated ===\n"];
    
    NSLog(@"BhyveController: monitorVMOutput - monitoring ended");
}

#pragma mark - Cleanup

- (void)cleanupTemporaryFiles
{
    NSLog(@"BhyveController: cleanupTemporaryFiles");
    
    // Remove virtual disk file
    NSString *diskPath = [NSString stringWithFormat:@"/tmp/%@.img", _vmName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:diskPath]) {
        NSError *error = nil;
        if ([[NSFileManager defaultManager] removeItemAtPath:diskPath error:&error]) {
            NSLog(@"BhyveController: Removed virtual disk: %@", diskPath);
        } else {
            NSLog(@"BhyveController: Failed to remove virtual disk %@: %@", diskPath, [error localizedDescription]);
        }
    }
    
    // Clean up any VM instances
    NSTask *destroyTask = [[NSTask alloc] init];
    [destroyTask setLaunchPath:@"/usr/sbin/bhyvectl"];
    [destroyTask setArguments:@[@"--destroy", [@"--vm=" stringByAppendingString:_vmName]]];
    
    NSPipe *pipe = [NSPipe pipe];
    [destroyTask setStandardOutput:pipe];
    [destroyTask setStandardError:pipe];
    
    @try {
        [destroyTask launch];
        [destroyTask waitUntilExit];
        int exitStatus = [destroyTask terminationStatus];
        if (exitStatus == 0) {
            NSLog(@"BhyveController: Cleaned up VM instance: %@", _vmName);
        }
        [destroyTask release];
    } @catch (NSException *exception) {
        NSLog(@"BhyveController: Error during VM cleanup: %@", [exception reason]);
        [destroyTask release];
    }
}

#pragma mark - GSAssistantWindowDelegate

- (void)assistantWindowWillFinish:(GSAssistantWindow *)window
{
    NSLog(@"BhyveController: assistantWindowWillFinish");
    [self stopVirtualMachine];
    [self cleanupTemporaryFiles];
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window
{
    NSLog(@"BhyveController: assistantWindowDidFinish");
    [self stopVirtualMachine];
    [self cleanupTemporaryFiles];
    [[window window] close];
    [NSApp terminate:nil];
}

- (void)assistantWindowDidCancel:(GSAssistantWindow *)window
{
    NSLog(@"BhyveController: assistantWindowDidCancel");
    [self stopVirtualMachine];
    [self cleanupTemporaryFiles];
    [[window window] close];
    [NSApp terminate:nil];
}

- (BOOL)testBhyveBasicFunction
{
    NSLog(@"BhyveController: testBhyveBasicFunction");
    
    // Try to create and immediately destroy a test VM to check permissions
    NSTask *testTask = [[NSTask alloc] init];
    [testTask setLaunchPath:@"/usr/sbin/bhyvectl"];
    [testTask setArguments:@[@"--create", @"--vm=bhyve-test"]];
    
    NSPipe *testPipe = [NSPipe pipe];
    [testTask setStandardOutput:testPipe];
    [testTask setStandardError:testPipe];
    
    @try {
        [testTask launch];
        [testTask waitUntilExit];
        int testStatus = [testTask terminationStatus];
        
        if (testStatus == 0) {
            NSLog(@"BhyveController: bhyve VM creation test successful");
            
            // Clean up test VM
            NSTask *destroyTask = [[NSTask alloc] init];
            [destroyTask setLaunchPath:@"/usr/sbin/bhyvectl"];
            [destroyTask setArguments:@[@"--destroy", @"--vm=bhyve-test"]];
            
            @try {
                [destroyTask launch];
                [destroyTask waitUntilExit];
                [destroyTask release];
            } @catch (NSException *exception) {
                NSLog(@"BhyveController: Error cleaning up test VM: %@", [exception reason]);
                [destroyTask release];
            }
            
            [testTask release];
            return YES;
        } else {
            NSData *errorData = [[testPipe fileHandleForReading] readDataToEndOfFile];
            NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSLog(@"BhyveController: bhyve VM creation test failed (exit code %d): %@", testStatus, errorOutput);
            [errorOutput release];
            [testTask release];
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"BhyveController: Error running bhyve test: %@", [exception reason]);
        [testTask release];
        return NO;
    }
}

#pragma mark - VNC Configuration

- (NSString *)generateVNCFramebufferConfig
{
    NSLog(@"BhyveController: generateVNCFramebufferConfig for port %ld", (long)_vncPort);
    
    // Enhanced framebuffer configuration for better X11 compatibility
    // The 'wait' option helps with synchronization issues that can occur with X11
    // Higher resolution provides better desktop experience
    // The framebuffer should be configured to work well with both text console and X11
    
    NSMutableString *vncConfig = [NSMutableString string];
    
    // Main framebuffer device with enhanced settings for X11 compatibility
    // Key parameters:
    // - wait: Wait for VNC client connection before starting VM (helps with sync)
    // - w=1280,h=1024: Good resolution that works well with X11
    // - tcp=0.0.0.0: Listen on all interfaces
    // - Using slot 29 to avoid conflicts with other devices
    [vncConfig appendFormat:@" -s 29:0,fbuf,tcp=0.0.0.0:%ld,w=1280,h=1024,wait", (long)_vncPort];
    
    // Add tablet device for better mouse handling in VNC
    // This provides absolute mouse positioning which works better than relative mouse in VNC
    [vncConfig appendString:@" -s 30:0,xhci,tablet"];
    
    NSLog(@"BhyveController: VNC framebuffer config: %@", vncConfig);
    return [NSString stringWithString:vncConfig];
}

- (void)showVNCConnectionInfo
{
    NSLog(@"BhyveController: showVNCConnectionInfo");
    
    if (!_enableVNC) {
        return;
    }
    
    NSInteger displayNumber = _vncPort - 5900;
    
    NSString *vncInfo = [NSString stringWithFormat:
        @"VNC Server Information:\n\n"
        @"• VNC Port: %ld\n"
        @"• Display Number: %ld\n"
        @"• VNC Address: localhost:%ld\n"
        @"• Alternative: :%ld\n\n"
        @"Resolution: 1280x1024\n"
        @"Wait Mode: Enabled (for better X11 sync)\n\n"
        @"Troubleshooting X11 Issues:\n"
        @"• Text console should appear immediately\n"
        @"• X11 may take 10-30 seconds to start\n"
        @"• If X11 doesn't appear, try restarting VNC viewer\n"
        @"• Some X11 sessions may need manual refresh\n"
        @"• Check VM log for X11 startup messages",
        (long)_vncPort, (long)displayNumber, (long)_vncPort, (long)displayNumber];
    
    [self showVMStatus:vncInfo];
}

@end
