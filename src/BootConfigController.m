#import "BootConfigController.h"
#import <unistd.h>  // For getuid()
#import "MainView.h"

// Custom view class to handle ESC key events in dialogs
@interface KeyHandlingView : NSView {
@public
    NSMutableDictionary *dialogData;
    BootConfigController *controller;
}
- (void)setDialogData:(NSMutableDictionary *)data;
- (void)setController:(BootConfigController *)ctrl;
@end

@implementation KeyHandlingView

- (void)setDialogData:(NSMutableDictionary *)data {
    dialogData = data;
}

- (void)setController:(BootConfigController *)ctrl {
    controller = ctrl;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = [event characters];
    if ([characters length] > 0) {
        unichar character = [characters characterAtIndex:0];
        if (character == 27) { // ESC key
            NSLog(@"ESC key pressed - canceling dialog");
            if (dialogData && controller) {
                [controller handleDialogCancel:self];
                return;
            }
        }
    }
    [super keyDown:event];
}

@end

@interface BootConfigController ()
- (void)showSuccessDialog:(NSString *)title message:(NSString *)message;
- (void)showErrorDialog:(NSString *)title message:(NSString *)message;
@end

@interface BootConfiguration : NSObject
{
    NSString *name;
    NSString *kernel;
    NSString *rootfs;
    NSString *options;
    NSString *size;
    NSString *date;
    BOOL active;
}

@property (nonatomic, retain) NSString *name;
@property (nonatomic, retain) NSString *kernel;
@property (nonatomic, retain) NSString *rootfs;
@property (nonatomic, retain) NSString *options;
@property (nonatomic, retain) NSString *size;
@property (nonatomic, retain) NSString *date;
@property (nonatomic, assign) BOOL active;

- (id)initWithName:(NSString *)configName kernel:(NSString *)kernelPath rootfs:(NSString *)rootfsPath options:(NSString *)bootOptions size:(NSString *)sizeInfo date:(NSString *)dateInfo active:(BOOL)isActive;

@end

@implementation BootConfiguration

@synthesize name, kernel, rootfs, options, size, date, active;

- (id)initWithName:(NSString *)configName kernel:(NSString *)kernelPath rootfs:(NSString *)rootfsPath options:(NSString *)bootOptions size:(NSString *)sizeInfo date:(NSString *)dateInfo active:(BOOL)isActive {
    if (self = [super init]) {
        self.name = configName;
        self.kernel = kernelPath;
        self.rootfs = rootfsPath;
        self.options = bootOptions;
        self.size = sizeInfo;
        self.date = dateInfo;
        self.active = isActive;
    }
    return self;
}

- (void)dealloc {
    [name release];
    [kernel release];
    [rootfs release];
    [options release];
    [size release];
    [date release];
    [super dealloc];
}

@end

@implementation BootConfigController

- (id)init {
    if (self = [super init]) {
        BOOL isRoot = (getuid() == 0);
        BOOL askpassValid = NO;
        BOOL sudoValid = NO;
        if (!isRoot) {
            // Check SUDO_ASKPASS
            char *askpass = getenv("SUDO_ASKPASS");
            if (askpass && [[NSFileManager defaultManager] isExecutableFileAtPath:[NSString stringWithUTF8String:askpass]]) {
                askpassValid = YES;
            }
            // Check sudo in PATH
            NSString *envPath = [[NSProcessInfo processInfo] environment][@"PATH"];
            NSArray *paths = [envPath componentsSeparatedByString:@":"];
            for (NSString *path in paths) {
                NSString *candidate = [path stringByAppendingPathComponent:@"sudo"];
                if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate]) {
                    sudoValid = YES;
                    break;
                }
            }
        }
        if (!isRoot && !(askpassValid && sudoValid)) {
            [self showErrorDialog:@"Insufficient Privileges" message:@"You must run as root, or have both SUDO_ASKPASS\nset to a valid executable and sudo available on your PATH."];
            exit(1);
        }
        bootConfigurations = [[NSMutableArray alloc] init];
        
        // Check if running as root and warn user
        if (getuid() != 0) {
            NSLog(@"WARNING: Application is not running as root (uid=%d)", getuid());
            NSLog(@"Creating and deleting boot environments will likely fail.");
            NSLog(@"Consider running with: sudo bash -c \". /usr/local/GNUstep/System/Makefiles/GNUstep.sh && openapp ./GNUstepApp.app\"");
        } else {
            NSLog(@"Application is running as root - full functionality available");
        }
        
        [self loadBootConfigurations];
        
        // Set up periodic refresh every 1.5 seconds
        [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(refreshConfigurations:) userInfo:nil repeats:YES];
    }
    return self;
}

- (void)dealloc {
    [bootConfigurations release];
    [mainView release];
    [super dealloc];
}

- (NSView *)createMainView {
    NSRect frame = NSMakeRect(0, 0, 800, 600); // Window size
    MainView *mv = [[MainView alloc] initWithFrame:frame];
    mainView = mv;

    // Set tableView frame to fill the entire view, no padding
    [mv.tableView setFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];

    // Set delegate and dataSource for table
    mv.tableView.delegate = self;
    mv.tableView.dataSource = self;
    configTableView = mv.tableView;

    // Set up double-click action
    [configTableView setTarget:self];
    [configTableView setDoubleAction:@selector(tableViewRowDoubleClicked:)];

    return mv;
}

- (void)tableViewRowDoubleClicked:(id)sender {
    NSInteger row = [configTableView clickedRow];
    if (row >= 0 && row < [bootConfigurations count]) {
        BootConfiguration *config = [bootConfigurations objectAtIndex:row];
        [self showBootEnvironmentDialog:config isEdit:YES];
    }
}

- (void)loadBootConfigurations {
    // Load existing boot environments from FreeBSD boot environments
    NSLog(@"=== Starting Boot Environment Load ===");
    
    [self loadFromBootEnvironments];
    [self loadFromLoaderConf];
    
    NSLog(@"Reloading table view with %lu boot environments", (unsigned long)[bootConfigurations count]);
    [configTableView reloadData];
    NSLog(@"=== Boot Environment Load Complete ===");
}

- (void)loadFromBootEnvironments {
    // Load ZFS boot environments using 'bectl list'
    NSLog(@"=== Loading ZFS Boot Environments ===");
    
    NSString *bectlPath = @"/sbin/bectl";
    NSLog(@"Attempting to run command: %@ list -H", bectlPath);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:bectlPath];
    [task setArguments:@[@"list", @"-H"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    
    @try {
        NSLog(@"Launching bectl task...");
        [task launch];
        [task waitUntilExit];
        
        NSLog(@"bectl task completed with exit status: %d", [task terminationStatus]);
        
        NSFileHandle *file = [pipe fileHandleForReading];
        NSData *data = [file readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        NSLog(@"bectl raw output length: %lu", (unsigned long)[output length]);
        NSLog(@"bectl raw output:\n%@", output);
        
        if ([task terminationStatus] == 0 && [output length] > 0) {
            NSLog(@"bectl command successful, parsing output...");
            [self parseBectlOutput:output];
        } else {
            NSLog(@"bectl command failed or returned empty output");
        }
        
        [output release];
    }
    @catch (NSException *exception) {
        NSLog(@"Exception running bectl: %@", [exception description]);
    }
    
    [task release];
    NSLog(@"=== End Loading ZFS Boot Environments ===");
}

- (void)parseBectlOutput:(NSString *)output {
    NSLog(@"=== Parsing bectl Output ===");
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    NSLog(@"Total lines to parse: %lu", (unsigned long)[lines count]);
    
    for (int i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSLog(@"Line %d: '%@'", i, line);
        
        if ([line length] == 0) {
            NSLog(@"Skipping empty line %d", i);
            continue;
        }
        
        NSArray *columns = [line componentsSeparatedByString:@"\t"];
        NSLog(@"Line %d has %lu columns", i, (unsigned long)[columns count]);
        
        for (int j = 0; j < [columns count]; j++) {
            NSLog(@"  Column %d: '%@'", j, [columns objectAtIndex:j]);
        }
        
        if ([columns count] >= 5) {
            NSString *beName = [columns objectAtIndex:0];
            NSString *activeFlag = [columns objectAtIndex:1];
            NSString *mountpoint = [columns objectAtIndex:2];
            NSString *space = [columns objectAtIndex:3];
            NSString *created = [columns objectAtIndex:4];
            
            NSLog(@"Parsing BE: name='%@', active='%@', mountpoint='%@', space='%@', created='%@'", 
                  beName, activeFlag, mountpoint, space, created);
            
            // Check if this boot environment is active
            // N = currently booted, R = on reboot, NR = both
            BOOL isActive = [activeFlag containsString:@"N"] || [activeFlag containsString:@"R"];
            NSLog(@"Boot environment '%@' is active: %@", beName, isActive ? @"YES" : @"NO");
            
            // Determine kernel path based on BE name
            NSString *kernelPath = @"/boot/kernel/kernel";
            if ([beName containsString:@"13."]) {
                kernelPath = @"/boot/kernel.old/kernel";
            }
            NSLog(@"Kernel path for '%@': %@", beName, kernelPath);
            
            // Determine root filesystem - use ZFS dataset name
            NSString *rootfs = [NSString stringWithFormat:@"zfs:%@", beName];
            NSLog(@"Root filesystem for '%@': %@", beName, rootfs);
            
            // Add creation date to options for informational purposes
            NSString *options = [NSString stringWithFormat:@"created=%@", created];
            NSLog(@"Options for '%@': %@", beName, options);
            
            BootConfiguration *config = [[BootConfiguration alloc] 
                initWithName:beName
                kernel:kernelPath
                rootfs:rootfs
                options:options
                size:space
                date:created
                active:isActive];
            
            [bootConfigurations addObject:config];
            [config release];
            
            NSLog(@"Added boot environment: %@", beName);
        } else {
            NSLog(@"Skipping line %d - insufficient columns (%lu)", i, (unsigned long)[columns count]);
        }
    }
    
    NSLog(@"=== End Parsing bectl Output ===");
    NSLog(@"Total boot environments loaded: %lu", (unsigned long)[bootConfigurations count]);
}

- (void)loadFromLoaderConf {
    // Load additional boot environments from /boot/loader.conf
    NSLog(@"Loading boot environments from /boot/loader.conf...");
    
    NSString *loaderConfPath = @"/boot/loader.conf";
    NSString *content = [NSString stringWithContentsOfFile:loaderConfPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    
    if (content) {
        [self parseLoaderConf:content];
    } else {
        NSLog(@"Could not read /boot/loader.conf");
    }
    
    // Also check for loader.conf.local
    NSString *loaderConfLocalPath = @"/boot/loader.conf.local";
    NSString *localContent = [NSString stringWithContentsOfFile:loaderConfLocalPath
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil];
    
    if (localContent) {
        NSLog(@"Loading boot environments from /boot/loader.conf.local...");
        [self parseLoaderConf:localContent];
    }
}

- (void)parseLoaderConf:(NSString *)content {
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    NSMutableDictionary *bootOptions = [[NSMutableDictionary alloc] init];
    
    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // Skip comments and empty lines
        if ([trimmedLine length] == 0 || [trimmedLine hasPrefix:@"#"]) {
            continue;
        }
        
        // Parse key=value pairs
        NSArray *parts = [trimmedLine componentsSeparatedByString:@"="];
        if ([parts count] >= 2) {
            NSString *key = [[parts objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *value = [[parts objectAtIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            // Remove quotes from value
            if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
                value = [value substringWithRange:NSMakeRange(1, [value length] - 2)];
            }
            
            [bootOptions setObject:value forKey:key];
        }
    }
    
    // Create boot environment from parsed options
    NSString *kernelPath = [bootOptions objectForKey:@"kernel"];
    NSString *rootfs = [bootOptions objectForKey:@"vfs.root.mountfrom"];
    
    if (!kernelPath) kernelPath = @"/boot/kernel/kernel";
    if (!rootfs) rootfs = @"ufs:/dev/ada0p2";
    
    // Check if we already have this boot environment
    BOOL alreadyExists = NO;
    for (BootConfiguration *config in bootConfigurations) {
        if ([[config kernel] isEqualToString:kernelPath] && [[config rootfs] isEqualToString:rootfs]) {
            alreadyExists = YES;
            break;
        }
    }
    
    if (!alreadyExists) {
        NSString *configName = @"System Default";
        NSString *options = @"";
        
        // Build options string from other loader.conf entries
        NSMutableArray *optionStrings = [[NSMutableArray alloc] init];
        for (NSString *key in bootOptions) {
            if (![key isEqualToString:@"kernel"] && ![key isEqualToString:@"vfs.root.mountfrom"]) {
                [optionStrings addObject:[NSString stringWithFormat:@"%@=%@", key, [bootOptions objectForKey:key]]];
            }
        }
        
        if ([optionStrings count] > 0) {
            options = [optionStrings componentsJoinedByString:@" "];
        }
        
        BootConfiguration *config = [[BootConfiguration alloc] 
            initWithName:configName
            kernel:kernelPath
            rootfs:rootfs
            options:options
            size:@"N/A"
            date:@"N/A"
            active:YES];
        
        [bootConfigurations addObject:config];
        [config release];
        
        NSLog(@"Loaded system default boot environment: %@", kernelPath);
        [optionStrings release];
    }
    
    [bootOptions release];
}

- (void)refreshConfigurations:(id)sender {
    NSLog(@"Refreshing boot environments...");
    
    NSLog(@"=== Refreshing Boot Environments ===");
    NSLog(@"Current boot environment count before refresh: %lu", (unsigned long)[bootConfigurations count]);
    
    // Clear existing boot environments
    [bootConfigurations removeAllObjects];
    NSLog(@"Cleared existing boot environments from memory");
    
    // Reload boot environments
    [self loadBootConfigurations];
    NSLog(@"Reloaded boot environments from system");
    NSLog(@"Boot environment count after refresh: %lu", (unsigned long)[bootConfigurations count]);
    
    [configTableView reloadData];
    NSLog(@"Table view reloaded");
    NSLog(@"=== Boot Environment Refresh Complete ===");
}

- (void)createConfiguration:(id)sender {
    NSLog(@"Opening dialog to create new boot environment...");
    [self showBootEnvironmentDialog:nil isEdit:NO];
}

- (void)editConfiguration:(id)sender {
    NSInteger selectedRow = [configTableView selectedRow];
    if (selectedRow < 0) {
        [self showErrorDialog:@"Edit Boot Environment" message:@"Please select a boot environment to edit."];
        return;
    }
    
    BootConfiguration *config = [bootConfigurations objectAtIndex:selectedRow];
    NSLog(@"Opening dialog to edit boot environment: %@", [config name]);
    [self showBootEnvironmentDialog:config isEdit:YES];
}

- (void)showBootEnvironmentDialog:(BootConfiguration *)config isEdit:(BOOL)isEdit {
    NSWindow *dialog = [[NSWindow alloc] 
        initWithContentRect:NSMakeRect(200, 200, 400, 300)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
        backing:NSBackingStoreBuffered
        defer:NO];
    
    [dialog setTitle:isEdit ? @"Edit Boot Environment" : @"Create Boot Environment"];
    
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    [dialog setContentView:contentView];
    
    // Create form fields
    NSTextField *nameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 240, 80, 20)];
    [nameLabel setStringValue:@"Name:"];
    [nameLabel setBezeled:NO];
    [nameLabel setDrawsBackground:NO];
    [nameLabel setEditable:NO];
    [contentView addSubview:nameLabel];
    
    NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(110, 240, 260, 20)];
    if (isEdit && config) {
        [nameField setStringValue:[config name]];
    }
    [contentView addSubview:nameField];
    
    NSTextField *kernelLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 210, 80, 20)];
    [kernelLabel setStringValue:@"Kernel:"];
    [kernelLabel setBezeled:NO];
    [kernelLabel setDrawsBackground:NO];
    [kernelLabel setEditable:NO];
    [contentView addSubview:kernelLabel];
    
    NSTextField *kernelField = [[NSTextField alloc] initWithFrame:NSMakeRect(110, 210, 260, 20)];
    if (isEdit && config) {
        [kernelField setStringValue:[config kernel]];
    } else {
        [kernelField setStringValue:@"/boot/kernel/kernel"];
    }
    [contentView addSubview:kernelField];
    
    NSTextField *rootfsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 180, 80, 20)];
    [rootfsLabel setStringValue:@"Root FS:"];
    [rootfsLabel setBezeled:NO];
    [rootfsLabel setDrawsBackground:NO];
    [rootfsLabel setEditable:NO];
    [contentView addSubview:rootfsLabel];
    
    NSTextField *rootfsField = [[NSTextField alloc] initWithFrame:NSMakeRect(110, 180, 260, 20)];
    if (isEdit && config) {
        [rootfsField setStringValue:[config rootfs]];
    } else {
        [rootfsField setStringValue:@"ufs:/dev/ada0p2"];
    }
    [contentView addSubview:rootfsField];
    
    NSTextField *optionsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 150, 80, 20)];
    [optionsLabel setStringValue:@"Options:"];
    [optionsLabel setBezeled:NO];
    [optionsLabel setDrawsBackground:NO];
    [optionsLabel setEditable:NO];
    [contentView addSubview:optionsLabel];
    
    NSTextField *optionsField = [[NSTextField alloc] initWithFrame:NSMakeRect(110, 150, 260, 20)];
    if (isEdit && config) {
        [optionsField setStringValue:[config options]];
    }
    [contentView addSubview:optionsField];
    

    
    // Create buttons
    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(200, 20, 80, 30)];
    [okButton setTitle:@"OK"];
    [okButton setTarget:self];
    [okButton setAction:@selector(handleDialogOK:)];
    [contentView addSubview:okButton];
    
    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(290, 20, 80, 30)];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(handleDialogCancel:)];
    [contentView addSubview:cancelButton];
    
    // Store dialog data for later use
    NSMutableDictionary *dialogData = [[NSMutableDictionary alloc] init];
    [dialogData setObject:dialog forKey:@"dialog"];
    [dialogData setObject:nameField forKey:@"nameField"];
    [dialogData setObject:kernelField forKey:@"kernelField"];
    [dialogData setObject:rootfsField forKey:@"rootfsField"];
    [dialogData setObject:optionsField forKey:@"optionsField"];
    [dialogData setObject:[NSNumber numberWithBool:isEdit] forKey:@"isEdit"];
    if (config) {
        [dialogData setObject:config forKey:@"config"];
    }
    
    // Store dialog data in button tags (hacky but works for this simple case)
    [okButton setTag:(NSInteger)dialogData];
    [cancelButton setTag:(NSInteger)dialogData];
    
    // Set up key event handling for ESC key
    [dialog setAcceptsMouseMovedEvents:YES];
    [dialog makeFirstResponder:nameField];
    
    // Create a custom content view that handles key events
    NSView *originalContentView = [dialog contentView];
    KeyHandlingView *keyHandlingView = [[KeyHandlingView alloc] initWithFrame:[originalContentView frame]];
    [keyHandlingView setDialogData:dialogData];
    [keyHandlingView setController:self];
    
    // Move all subviews to the key handling view
    NSArray *subviews = [[originalContentView subviews] copy];
    for (NSView *subview in subviews) {
        [subview removeFromSuperview];
        [keyHandlingView addSubview:subview];
    }
    [dialog setContentView:keyHandlingView];
    [keyHandlingView release];
    [subviews release];
    
    [dialog center];
    [dialog makeKeyAndOrderFront:nil];
}

- (void)handleDialogOK:(id)sender {
    NSButton *button = (NSButton *)sender;
    NSMutableDictionary *dialogData = (NSMutableDictionary *)[button tag];
    
    NSWindow *dialog = [dialogData objectForKey:@"dialog"];
    NSTextField *nameField = [dialogData objectForKey:@"nameField"];
    NSTextField *kernelField = [dialogData objectForKey:@"kernelField"];
    NSTextField *rootfsField = [dialogData objectForKey:@"rootfsField"];
    NSTextField *optionsField = [dialogData objectForKey:@"optionsField"];
    BOOL isEdit = [[dialogData objectForKey:@"isEdit"] boolValue];
    BootConfiguration *existingConfig = [dialogData objectForKey:@"config"];
    
    NSString *name = [nameField stringValue];
    NSString *kernel = [kernelField stringValue];
    NSString *rootfs = [rootfsField stringValue];
    NSString *options = [optionsField stringValue];
    
    if ([name length] == 0) {
        [self showErrorDialog:@"Validation Error" message:@"Boot environment name is required."];
        return;
    }
    
    if ([kernel length] == 0) {
        [self showErrorDialog:@"Validation Error" message:@"Kernel path is required."];
        return;
    }
    
    if (isEdit) {
        // Edit existing boot environment
        if (existingConfig) {
            // Actually update the ZFS boot environment using bectl
            BOOL bectlSuccess = [self updateBootEnvironmentWithBectl:[existingConfig name] newName:name];
            if (!bectlSuccess) {
                [self showErrorDialog:@"Update Failed" message:[NSString stringWithFormat:@"Failed to update boot environment '%@'. Check console for details.", [existingConfig name]]];
                return;
            }
            [existingConfig setName:name];
            [existingConfig setKernel:kernel];
            [existingConfig setRootfs:rootfs];
            [existingConfig setOptions:options];
            [self showSuccessDialog:@"Boot Environment Updated" message:[NSString stringWithFormat:@"Boot environment '%@' has been updated successfully.", name]];
        }
    } else {
        // Create new boot environment
        // Check if name already exists
        for (BootConfiguration *config in bootConfigurations) {
            if ([[config name] isEqualToString:name]) {
                [self showErrorDialog:@"Boot Environment Exists" message:[NSString stringWithFormat:@"Boot environment '%@' already exists.", name]];
                return;
            }
        }
        
        // Actually create the ZFS boot environment using bectl
        BOOL bectlSuccess = [self createBootEnvironmentWithBectl:name];
        
        if (bectlSuccess) {
            NSLog(@"Successfully created ZFS boot environment '%@' with bectl", name);
            
            BootConfiguration *newConfig = [[BootConfiguration alloc] 
                initWithName:name 
                kernel:kernel 
                rootfs:rootfs 
                options:options 
                size:@"New"
                date:@"Just created"
                active:NO];  // New boot environments are not active by default
            
            [bootConfigurations addObject:newConfig];
            [newConfig release];
            
            [self showSuccessDialog:@"Boot Environment Created" message:[NSString stringWithFormat:@"Boot environment '%@' has been created successfully with bectl.", name]];
        } else {
            NSLog(@"Failed to create ZFS boot environment '%@' with bectl", name);
            [self showErrorDialog:@"Creation Failed" message:[NSString stringWithFormat:@"Failed to create boot environment '%@'. Check console for details.", name]];
            return;
        }
    }
    
    [configTableView reloadData];
    [dialog close];
    [dialogData release];
}

- (void)handleDialogCancel:(id)sender {
    NSMutableDictionary *dialogData;
    
    if ([sender isKindOfClass:[NSButton class]]) {
        // Called from Cancel button
        NSButton *button = (NSButton *)sender;
        dialogData = (NSMutableDictionary *)[button tag];
    } else if ([sender isKindOfClass:[KeyHandlingView class]]) {
        // Called from ESC key handler
        KeyHandlingView *view = (KeyHandlingView *)sender;
        dialogData = view->dialogData;
    } else {
        NSLog(@"handleDialogCancel called from unknown sender type");
        return;
    }
    
    NSWindow *dialog = [dialogData objectForKey:@"dialog"];
    [dialog close];
    [dialogData release];
}

- (void)deleteConfiguration:(id)sender {
    NSInteger selectedRow = [configTableView selectedRow];
    if (selectedRow < 0) {
        [self showErrorDialog:@"Delete Boot Environment" message:@"Please select a boot environment to delete."];
        return;
    }
    
    BootConfiguration *config = [bootConfigurations objectAtIndex:selectedRow];
    NSString *configName = [config name];
    
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Delete Boot Environment"];
    [alert setInformativeText:[NSString stringWithFormat:@"Are you sure you want to delete the boot environment '%@'? This will permanently remove the ZFS boot environment.", configName]];
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSInteger result = [alert runModal];
    if (result == NSAlertFirstButtonReturn) {
        // Actually delete the ZFS boot environment using bectl
        BOOL bectlSuccess = [self deleteBootEnvironmentWithBectl:configName];
        
        if (bectlSuccess) {
            NSLog(@"Successfully deleted ZFS boot environment '%@' with bectl", configName);
            [bootConfigurations removeObjectAtIndex:selectedRow];
            [configTableView reloadData];
            [self showSuccessDialog:@"Boot Environment Deleted" message:[NSString stringWithFormat:@"Boot environment '%@' has been deleted successfully.", configName]];
        } else {
            NSLog(@"Failed to delete ZFS boot environment '%@' with bectl", configName);
            [self showErrorDialog:@"Delete Failed" message:[NSString stringWithFormat:@"Failed to delete boot environment '%@'. Check the console for details.", configName]];
        }
    }
}

- (void)setActiveConfiguration:(id)sender {
    NSInteger selectedRow = [configTableView selectedRow];
    if (selectedRow < 0) {
        [self showErrorDialog:@"Set Active Boot Environment" message:@"Please select a boot environment to set as active."];
        return;
    }
    
    BootConfiguration *selectedConfig = [bootConfigurations objectAtIndex:selectedRow];
    NSString *beName = [selectedConfig name];
    
    // Call bectl activate
    BOOL bectlSuccess = [self activateBootEnvironmentWithBectl:beName];
    if (bectlSuccess) {
        // Deactivate all boot environments in UI
        for (BootConfiguration *config in bootConfigurations) {
            [config setActive:NO];
        }
        // Activate selected boot environment in UI
        [selectedConfig setActive:YES];
        [configTableView reloadData];
        NSLog(@"Boot environment '%@' set as active via bectl.", beName);
        [self showSuccessDialog:@"Active Boot Environment Set" message:[NSString stringWithFormat:@"Boot environment '%@' has been set as active using bectl.", beName]];
    } else {
        NSLog(@"Failed to activate boot environment '%@' with bectl", beName);
        [self showErrorDialog:@"Activation Failed" message:[NSString stringWithFormat:@"Failed to activate boot environment '%@'. Check the console for details.", beName]];
    }
}

// Activate a boot environment using bectl activate
- (BOOL)activateBootEnvironmentWithBectl:(NSString *)beName {
    NSLog(@"=== Activating ZFS Boot Environment with bectl ===");
    NSLog(@"Boot environment name: %@", beName);
    if (getuid() != 0) {
        char *askpass = getenv("SUDO_ASKPASS");
        BOOL askpassValid = NO;
        if (askpass && [[NSFileManager defaultManager] isExecutableFileAtPath:[NSString stringWithUTF8String:askpass]]) {
            askpassValid = YES;
        }
        if (!askpassValid) {
            [self showErrorDialog:@"SUDO_ASKPASS Not Set" message:@"SUDO_ASKPASS is not set or does not point to a valid executable. Cannot run sudo -A. Please set SUDO_ASKPASS to a valid askpass binary."];
            return NO;
        }
        NSLog(@"WARNING: Not running as root (uid=%d). Using sudo -A for bectl activate.", getuid());
    }
    NSString *bectlPath = @"/sbin/bectl";
    NSArray *arguments;
    if (getuid() != 0) {
        arguments = @[@"sudo", @"-A", bectlPath, @"activate", beName];
        bectlPath = @"/usr/bin/env";
    } else {
        arguments = @[@"activate", beName];
    }
    
    NSLog(@"Executing command: %@ %@", bectlPath, [arguments componentsJoinedByString:@" "]);
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:bectlPath];
    [task setArguments:arguments];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    NSFileHandle *outputHandle = [outputPipe fileHandleForReading];
    NSFileHandle *errorHandle = [errorPipe fileHandleForReading];
    @try {
        NSLog(@"Launching bectl activate task...");
        [task launch];
        [task waitUntilExit];
        int exitStatus = [task terminationStatus];
        NSLog(@"bectl activate task completed with exit status: %d", exitStatus);
        NSData *outputData = [outputHandle readDataToEndOfFile];
        NSData *errorData = [errorHandle readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *error = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        if (output && [output length] > 0) {
            NSLog(@"bectl activate output: %@", output);
        }
        if (error && [error length] > 0) {
            NSLog(@"bectl activate error: %@", error);
        }
        [output release];
        [error release];
        if (exitStatus == 0) {
            NSLog(@"Successfully activated boot environment '%@'", beName);
            return YES;
        } else {
            NSLog(@"Failed to activate boot environment '%@' (exit status: %d)", beName, exitStatus);
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception while activating boot environment: %@", [exception reason]);
        return NO;
    } @finally {
        [task release];
    }
}

- (BOOL)createBootEnvironmentWithBectl:(NSString *)beName {
    NSLog(@"=== Creating ZFS Boot Environment with bectl ===");
    NSLog(@"Boot environment name: %@", beName);
    
    // Check if we're running as root
    if (getuid() != 0) {
        char *askpass = getenv("SUDO_ASKPASS");
        BOOL askpassValid = NO;
        if (askpass && [[NSFileManager defaultManager] isExecutableFileAtPath:[NSString stringWithUTF8String:askpass]]) {
            askpassValid = YES;
        }
        if (!askpassValid) {
            [self showErrorDialog:@"SUDO_ASKPASS Not Set" message:@"SUDO_ASKPASS is not set or does not point to a valid executable. Cannot run sudo -A. Please set SUDO_ASKPASS to a valid askpass binary."];
            return NO;
        }
        NSLog(@"WARNING: Not running as root (uid=%d). Using sudo -A for bectl create.", getuid());
    }
    
    // Create bectl create command with sudo if needed
    NSString *bectlPath = @"/sbin/bectl";
    NSArray *arguments;
    if (getuid() != 0) {
        arguments = @[@"sudo", @"-A", bectlPath, @"create", beName];
        bectlPath = @"/usr/bin/env";
    } else {
        arguments = @[@"create", beName];
    }
    
    NSLog(@"Executing command: %@ %@", bectlPath, [arguments componentsJoinedByString:@" "]);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:bectlPath];
    [task setArguments:arguments];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    NSFileHandle *outputHandle = [outputPipe fileHandleForReading];
    NSFileHandle *errorHandle = [errorPipe fileHandleForReading];
    
    @try {
        NSLog(@"Launching bectl create task...");
        [task launch];
        [task waitUntilExit];
        
        int exitStatus = [task terminationStatus];
        NSLog(@"bectl create task completed with exit status: %d", exitStatus);
        
        // Read output and error
        NSData *outputData = [outputHandle readDataToEndOfFile];
        NSData *errorData = [errorHandle readDataToEndOfFile];
        
        NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *error = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        if (output && [output length] > 0) {
            NSLog(@"bectl create output: %@", output);
        }
        
        if (error && [error length] > 0) {
            NSLog(@"bectl create error: %@", error);
        }
        
        [output release];
        [error release];
        
        if (exitStatus == 0) {
            NSLog(@"Successfully created boot environment '%@'", beName);
            return YES;
        } else {
            NSLog(@"Failed to create boot environment '%@' (exit status: %d)", beName, exitStatus);
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception while creating boot environment: %@", [exception reason]);
        return NO;
    } @finally {
        [task release];
    }
}

- (BOOL)deleteBootEnvironmentWithBectl:(NSString *)beName {
    NSLog(@"=== Deleting ZFS Boot Environment with bectl ===");
    NSLog(@"Boot environment name: %@", beName);
    
    // Check if we're running as root
    if (getuid() != 0) {
        char *askpass = getenv("SUDO_ASKPASS");
        BOOL askpassValid = NO;
        if (askpass && [[NSFileManager defaultManager] isExecutableFileAtPath:[NSString stringWithUTF8String:askpass]]) {
            askpassValid = YES;
        }
        if (!askpassValid) {
            [self showErrorDialog:@"SUDO_ASKPASS Not Set" message:@"SUDO_ASKPASS is not set or does not point to a valid executable. Cannot run sudo -A. Please set SUDO_ASKPASS to a valid askpass binary."];
            return NO;
        }
        NSLog(@"WARNING: Not running as root (uid=%d). Using sudo -A for bectl destroy.", getuid());
    }
    
    // Create bectl destroy command with sudo if needed
    NSString *bectlPath = @"/sbin/bectl";
    NSArray *arguments;
    if (getuid() != 0) {
        arguments = @[@"sudo", @"-A", bectlPath, @"destroy", @"-F", beName];
        bectlPath = @"/usr/bin/env";
    } else {
        arguments = @[@"destroy", @"-F", beName];  // -F flag to force destruction
    }
    
    NSLog(@"Executing command: %@ %@", bectlPath, [arguments componentsJoinedByString:@" "]);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:bectlPath];
    [task setArguments:arguments];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    NSFileHandle *outputHandle = [outputPipe fileHandleForReading];
    NSFileHandle *errorHandle = [errorPipe fileHandleForReading];
    
    @try {
        NSLog(@"Launching bectl destroy task...");
        [task launch];
        [task waitUntilExit];
        
        int exitStatus = [task terminationStatus];
        NSLog(@"bectl destroy task completed with exit status: %d", exitStatus);
        
        // Read output and error
        NSData *outputData = [outputHandle readDataToEndOfFile];
        NSData *errorData = [errorHandle readDataToEndOfFile];
        
        NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *error = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        if (output && [output length] > 0) {
            NSLog(@"bectl destroy output: %@", output);
        }
        
        if (error && [error length] > 0) {
            NSLog(@"bectl destroy error: %@", error);
        }
        
        [output release];
        [error release];
        
        if (exitStatus == 0) {
            NSLog(@"Successfully deleted boot environment '%@'", beName);
            return YES;
        } else {
            NSLog(@"Failed to delete boot environment '%@' (exit status: %d)", beName, exitStatus);
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception while deleting boot environment: %@", [exception reason]);
        return NO;
    } @finally {
        [task release];
    }
}

// Update a boot environment using bectl rename if the name changes
- (BOOL)updateBootEnvironmentWithBectl:(NSString *)oldName newName:(NSString *)newName {
    if ([oldName isEqualToString:newName]) {
        // No rename needed
        return YES;
    }
    NSLog(@"=== Renaming ZFS Boot Environment with bectl ===");
    NSLog(@"Old name: %@, New name: %@", oldName, newName);
    if (getuid() != 0) {
        char *askpass = getenv("SUDO_ASKPASS");
        BOOL askpassValid = NO;
        if (askpass && [[NSFileManager defaultManager] isExecutableFileAtPath:[NSString stringWithUTF8String:askpass]]) {
            askpassValid = YES;
        }
        if (!askpassValid) {
            [self showErrorDialog:@"SUDO_ASKPASS Not Set" message:@"SUDO_ASKPASS is not set or does not point to a valid executable. Cannot run sudo -A. Please set SUDO_ASKPASS to a valid askpass binary."];
            return NO;
        }
        NSLog(@"WARNING: Not running as root (uid=%d). Using sudo -A for bectl rename.", getuid());
    }
    NSString *bectlPath = @"/sbin/bectl";
    NSArray *arguments;
    if (getuid() != 0) {
        arguments = @[@"sudo", @"-A", bectlPath, @"rename", oldName, newName];
        bectlPath = @"/usr/bin/env";
    } else {
        arguments = @[@"rename", oldName, newName];
    }
    NSLog(@"Executing command: %@ %@", bectlPath, [arguments componentsJoinedByString:@" "]);
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:bectlPath];
    [task setArguments:arguments];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    NSFileHandle *outputHandle = [outputPipe fileHandleForReading];
    NSFileHandle *errorHandle = [errorPipe fileHandleForReading];
    @try {
        NSLog(@"Launching bectl rename task...");
        [task launch];
        [task waitUntilExit];
        int exitStatus = [task terminationStatus];
        NSLog(@"bectl rename task completed with exit status: %d", exitStatus);
        NSData *outputData = [outputHandle readDataToEndOfFile];
        NSData *errorData = [errorHandle readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *error = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        if (output && [output length] > 0) {
            NSLog(@"bectl rename output: %@", output);
        }
        if (error && [error length] > 0) {
            NSLog(@"bectl rename error: %@", error);
        }
        [output release];
        [error release];
        if (exitStatus == 0) {
            NSLog(@"Successfully renamed boot environment '%@' to '%@'", oldName, newName);
            return YES;
        } else {
            NSLog(@"Failed to rename boot environment '%@' to '%@' (exit status: %d)", oldName, newName, exitStatus);
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception while renaming boot environment: %@", [exception reason]);
        return NO;
    } @finally {
        [task release];
    }
}

// Table View Data Source Methods
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [bootConfigurations count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    BootConfiguration *config = [bootConfigurations objectAtIndex:row];
    NSString *identifier = [tableColumn identifier];
    
    if ([identifier isEqualToString:@"name"]) {
        return [config name];
    } else if ([identifier isEqualToString:@"kernel"]) {
        return [config kernel];
    } else if ([identifier isEqualToString:@"rootfs"]) {
        return [config rootfs];
    } else if ([identifier isEqualToString:@"size"]) {
        return [config size];
    } else if ([identifier isEqualToString:@"date"]) {
        return [config date];
    } else if ([identifier isEqualToString:@"active"]) {
        return [config active] ? @"Yes" : @"No";
    }
    
    return @"";
}

// Table View Delegate Methods
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    // Selection changed - no form fields to update anymore
    NSInteger selectedRow = [configTableView selectedRow];
    if (selectedRow >= 0) {
        BootConfiguration *config = [bootConfigurations objectAtIndex:selectedRow];
        NSLog(@"Selected boot environment: %@", [config name]);
    }
}

- (void)tableView:(NSTableView *)tableView mouseDownAtRow:(NSInteger)row {
    // Handle double-click to edit
    NSEvent *event = [NSApp currentEvent];
    if ([event clickCount] == 2 && row >= 0) {
        NSLog(@"Double-clicked row %ld - editing boot environment", (long)row);
        BootConfiguration *config = [bootConfigurations objectAtIndex:row];
        [self showBootEnvironmentDialog:config isEdit:YES];
    }
}

- (void)showSuccessDialog:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:message];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSInformationalAlertStyle];
    [alert runModal];
    [alert release];
}

- (void)showErrorDialog:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:message];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSCriticalAlertStyle];
    [alert runModal];
    [alert release];
}

@end
