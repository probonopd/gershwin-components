#import "GSUTMAssistant.h"
#import "GSUTMConfiguration.h"
#import "GSUTMMainWindowController.h"
#import "GSAssistantFramework.h"
#import "AppearanceMetrics.h"

@interface GSUTMAssistant () <GSAssistantWindowDelegate>
{
    GSUTMMainWindowController *_owner;
    GSUTMConfiguration *_config;
    BOOL _isEditing;
    /* Step 0 - Name */
    NSTextField *_nameField;
    NSTextField *_nameError;
    NSPopUpButton *_archPopup;
    GSAssistantStep *_nameStep;
    /* Step 1 - System */
    NSTextField *_memField;
    NSTextField *_memError;
    NSPopUpButton *_cpuPopup;
    NSPopUpButton *_targetPopup;
    GSAssistantStep *_sysStep;
    /* Step 0 - Images */
    NSTextField *_diskField;
    NSTextField *_cdField;
    NSTextField *_storageError;
    GSAssistantStep *_imagesStep;
    /* Step 2 - Storage */
    /* Step 3 - Devices */
    NSPopUpButton *_netPopup;
    NSButton *_netCheck;
    NSPopUpButton *_soundPopup;
    NSButton *_soundCheck;
    NSPopUpButton *_linuxDisplayPopup;
    GSAssistantStep *_devicesStep;
    /* Step 4 - Summary */
    GSAssistantStep *_summaryStep;
}
@end

@implementation GSUTMAssistant

- (instancetype)initWithOwner:(GSUTMMainWindowController *)owner
{
    self = [super init];
    if (self) {
        _owner = owner;
        _config = [[GSUTMConfiguration alloc] init];
    }
    return self;
}

- (void)editConfiguration:(GSUTMConfiguration *)config
{
    [_config release];
    _config = [config retain];
    _isEditing = YES;
    [self runNewVMAssistant];
}

- (void)runNewVMAssistant
{
    NSArray *steps = @[
        [self _imagesStep],
        [self _nameStep],
        [self _systemStep],
        [self _devicesStep],
        [self _summaryStep],
    ];

    GSAssistantWindow *assistant = [[GSAssistantWindow alloc]
        initWithLayoutStyle:GSAssistantLayoutStyleInstaller
                     title:_isEditing ? @"Edit Configuration" : @"New Virtual Machine"
                      icon:nil
                     steps:steps];
    assistant.delegate = self;
    assistant.showsSidebar = YES;
    assistant.showsStepIndicators = YES;
    assistant.allowsCancel = YES;
    [assistant showWindow:nil];
    /* The delegate is set after init, which is when the initial step was shown;
       re-show it so the preload callback fires. */
    [assistant showCurrentStep];
}

#pragma mark - Validation Helpers

- (void)_updateNameValidation
{
    NSString *name = [_nameField stringValue];
    BOOL valid = ([name length] > 0);
    if (valid) {
        [_nameError setStringValue:@""];
    } else {
        [_nameError setStringValue:@"VM name is required"];
    }
    _nameStep.canProceed = valid;
    [_nameStep.assistantWindow updateNavigationButtons];
}

- (void)_updateMemoryValidation
{
    NSInteger val = [_memField integerValue];
    BOOL valid = (val >= 64 && val <= 1048576);
    if (valid) {
        [_memError setStringValue:@""];
    } else {
        [_memError setStringValue:@"Enter 64-1048576 MB"];
    }
    _sysStep.canProceed = valid;
    [_sysStep.assistantWindow updateNavigationButtons];
}

- (void)_preloadFields
{
    if (_config.baseURL) [_config resolveDrivePathsWithBaseURL:_config.baseURL];
    if (_nameField) [_nameField setStringValue:_config.name ?: @"My VM"];
    if (_archPopup) {
        if ([_config.architecture isEqualToString:@"aarch64"])
            [_archPopup selectItemAtIndex:1];
    }
    if (_memField) [_memField setStringValue:[NSString stringWithFormat:@"%lu", (unsigned long)_config.memorySize]];
    if (_cpuPopup) {
        int cores = (int)_config.cpuCount;
        if (cores < 1) cores = 1;
        if (cores > 16) cores = 16;
        [_cpuPopup selectItemAtIndex:cores - 1];
    }
    if (_targetPopup) {
        if ([_config.target isEqualToString:@"pc"]) [_targetPopup selectItemAtIndex:1];
        else if ([_config.target isEqualToString:@"virt"]) [_targetPopup selectItemAtIndex:2];
    }
    if (_diskField) [_diskField setStringValue:_config.diskImagePath ?: @""];
    if (_cdField) [_cdField setStringValue:_config.cdromImagePath ?: @""];
    if (_netPopup) {
        NSString *card = _config.networkCard;
        NSArray *items = @[@"rtl8139", @"e1000", @"virtio-net-pci", @"ne2k_pci"];
        NSUInteger idx = [items indexOfObject:card];
        if (idx != NSNotFound) [_netPopup selectItemAtIndex:idx];
    }
    if (_netCheck) [_netCheck setState:_config.networkEnabled ? NSOnState : NSOffState];
    if (_soundPopup) {
        NSString *card = _config.soundCard;
        NSArray *items = @[@"ac97", @"hda", @"sb16"];
        NSUInteger idx = [items indexOfObject:card];
        if (idx != NSNotFound) [_soundPopup selectItemAtIndex:idx];
    }
    if (_soundCheck) [_soundCheck setState:_config.soundEnabled ? NSOnState : NSOffState];
    if (_linuxDisplayPopup) {
        NSString *card = _config.linuxHostDisplayCard;
        NSArray *items = [_linuxDisplayPopup itemTitles];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSString *title = items[i];
            NSRange rec = [title rangeOfString:@" (recommended)"];
            if (rec.location != NSNotFound)
                title = [title substringToIndex:rec.location];
            if ([title isEqualToString:card]) {
                [_linuxDisplayPopup selectItemAtIndex:i];
                break;
            }
        }
    }
}

- (void)_updateStorageValidation
{
    NSString *diskPath = [_diskField stringValue];
    NSString *cdPath = [_cdField stringValue];
    BOOL hasDisk = ([diskPath length] > 0);
    BOOL hasCd = ([cdPath length] > 0);

    if (!hasDisk && !hasCd) {
        [_storageError setStringValue:@"At least one of Hard Disk or CDROM must be provided."];
    } else {
        [_storageError setStringValue:@""];
    }
    _imagesStep.canProceed = (hasDisk || hasCd);
    [_imagesStep.assistantWindow updateNavigationButtons];
}

- (void)_textChanged:(NSNotification *)note
{
    NSTextField *field = [note object];
    if (field == _nameField) [self _updateNameValidation];
    if (field == _memField) [self _updateMemoryValidation];
    if (field == _diskField || field == _cdField) {
        [self _updateStorageValidation];
        /* Guess name and architecture from the disk path */
        if (field == _diskField && [[_diskField stringValue] length] > 0) {
            NSString *guessed = [self _guessNameFromPath:[_diskField stringValue]];
            if ([guessed length] > 0 && _nameField) {
                [_nameField setStringValue:guessed];
                [self _updateNameValidation];
            }
            if (_archPopup) {
                NSString *arch = [self _guessArchFromPath:[_diskField stringValue]];
                [_archPopup selectItemAtIndex:[arch isEqualToString:@"aarch64"] ? 1 : 0];
            }
        }
    }
}

#pragma mark - Guessing

- (NSString *)_guessNameFromPath:(NSString *)path
{
    NSString *file = [[path lastPathComponent] stringByDeletingPathExtension];
    /* Remove common extensions like .img, .iso, .qcow2, .raw */
    NSString *ext = [[path pathExtension] lowercaseString];
    if ([ext isEqualToString:@"img"] || [ext isEqualToString:@"iso"] ||
        [ext isEqualToString:@"qcow2"] || [ext isEqualToString:@"raw"]) {
        file = [[file stringByDeletingPathExtension] length] > 0 ?
                [file stringByDeletingPathExtension] : file;
    }
    /* Clean up common patterns */
    file = [file stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    file = [file stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    /* Title case */
    if ([file length] > 0) {
        file = [file stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return file;
}

- (NSString *)_guessArchFromPath:(NSString *)path
{
    NSString *lower = [[path lastPathComponent] lowercaseString];
    if ([lower containsString:@"arm64"] || [lower containsString:@"aarch64"] ||
        [lower containsString:@"raspi"] || [lower containsString:@"raspberry"] ||
        [lower containsString:@"m1"] || [lower containsString:@"apple silicon"]) {
        return @"aarch64";
    }
    return @"x86_64";
}

#pragma mark - Step 0: Select Images

- (GSAssistantStep *)_imagesStep
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];

    [self _label:@"Disk Image:" x:0 y:200 w:120 in:v];
    _diskField = [self _field:NSMakeRect(0, 170, 256, METRICS_TEXT_INPUT_FIELD_HEIGHT) placeholder:@"Disk path"];
    [v addSubview:_diskField];
    [v addSubview:[self _btnWithTitle:@"Browse" frame:NSMakeRect(264, 170, 80, METRICS_TEXT_INPUT_FIELD_HEIGHT) action:@selector(_browseDisk)]];

    [self _label:@"CDROM:" x:0 y:130 w:120 in:v];
    _cdField = [self _field:NSMakeRect(0, 100, 256, METRICS_TEXT_INPUT_FIELD_HEIGHT) placeholder:@"ISO path"];
    [v addSubview:_cdField];
    [v addSubview:[self _btnWithTitle:@"Browse" frame:NSMakeRect(264, 100, 80, METRICS_TEXT_INPUT_FIELD_HEIGHT) action:@selector(_browseCdrom)]];

    /* Observe changes for guessing */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_textChanged:)
                                                 name:NSControlTextDidChangeNotification
                                               object:_diskField];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_textChanged:)
                                                 name:NSControlTextDidChangeNotification
                                               object:_cdField];

    GSAssistantStep *s = [[GSAssistantStep alloc] initWithTitle:@"Select Images"
                                                   description:@"Choose a disk image and optional install media."
                                                          view:v];
    s.canProceed = NO;
    _imagesStep = s;
    return s;
}

#pragma mark - Step 1: Name and Architecture

- (GSAssistantStep *)_nameStep
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];

    [self _label:@"VM Name:" x:0 y:200 w:120 in:v];
    _nameField = [self _field:NSMakeRect(130, 200, 260, 22) placeholder:@"e.g. Windows 10"];
    [_nameField setStringValue:@"My VM"];
    [v addSubview:_nameField];

    _nameError = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 178, 260, 16)];
    [_nameError setTextColor:[NSColor redColor]];
    [_nameError setBezeled:NO];
    [_nameError setEditable:NO];
    [_nameError setDrawsBackground:NO];
    [_nameError setFont:[NSFont systemFontOfSize:10]];
    [v addSubview:_nameError];

    [self _label:@"Architecture:" x:0 y:140 w:120 in:v];
    _archPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 140, 180, 24) pullsDown:NO];
    [_archPopup addItemsWithTitles:@[@"x86_64", @"aarch64"]];
    [v addSubview:_archPopup];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_textChanged:)
                                                 name:NSControlTextDidChangeNotification
                                               object:_nameField];

    _nameStep = [[GSAssistantStep alloc] initWithTitle:@"Name and Architecture"
                                           description:@"Review or change the detected name and architecture."
                                                  view:v];
    _nameStep.canProceed = YES;
    return _nameStep;
}

#pragma mark - Step 1: System

- (GSAssistantStep *)_systemStep
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];

    [self _label:@"Memory:" x:0 y:200 w:120 in:v];
    _memField = [self _field:NSMakeRect(130, 200, 100, 22) placeholder:@"512"];
    [_memField setStringValue:@"2048"];
    [v addSubview:_memField];
    [self _label:@"MB" x:240 y:200 w:40 in:v];

    _memError = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 178, 200, 16)];
    [_memError setTextColor:[NSColor redColor]];
    [_memError setBezeled:NO];
    [_memError setEditable:NO];
    [_memError setDrawsBackground:NO];
    [_memError setFont:[NSFont systemFontOfSize:10]];
    [v addSubview:_memError];

    [self _label:@"CPU Cores:" x:0 y:140 w:120 in:v];
    _cpuPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 140, 80, 24) pullsDown:NO];
    for (int i = 1; i <= 16; i++) {
        [_cpuPopup addItemWithTitle:[NSString stringWithFormat:@"%d", i]];
    }
    [_cpuPopup selectItemAtIndex:1]; /* 2 cores default */
    [v addSubview:_cpuPopup];

    [self _label:@"Machine:" x:0 y:100 w:120 in:v];
    _targetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 100, 200, 24) pullsDown:NO];
    [_targetPopup addItemsWithTitles:@[@"q35 (modern, recommended)", @"pc (legacy)", @"virt (ARM)"]];
    [v addSubview:_targetPopup];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_textChanged:)
                                                 name:NSControlTextDidChangeNotification
                                               object:_memField];

    _sysStep = [[GSAssistantStep alloc] initWithTitle:@"System"
                                           description:@"Configure memory and CPU."
                                                  view:v];
    _sysStep.canProceed = YES;
    return _sysStep;
}

#pragma mark - Step 3: Devices

- (GSAssistantStep *)_devicesStep
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];

    [self _label:@"Network:" x:0 y:200 w:120 in:v];
    _netPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 200, 180, 24) pullsDown:NO];
    [_netPopup addItemsWithTitles:@[@"rtl8139", @"e1000", @"virtio-net-pci", @"ne2k_pci"]];
    [v addSubview:_netPopup];

    _netCheck = [[NSButton alloc] initWithFrame:NSMakeRect(320, 200, 100, 22)];
    [_netCheck setButtonType:NSSwitchButton];
    [_netCheck setTitle:@"Enabled"];
    [_netCheck setState:NSOnState];
    [v addSubview:_netCheck];

    [self _label:@"Sound:" x:0 y:160 w:120 in:v];
    _soundPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 160, 180, 24) pullsDown:NO];
    [_soundPopup addItemsWithTitles:@[@"ac97", @"hda", @"sb16"]];
    [v addSubview:_soundPopup];

    _soundCheck = [[NSButton alloc] initWithFrame:NSMakeRect(320, 160, 100, 22)];
    [_soundCheck setButtonType:NSSwitchButton];
    [_soundCheck setTitle:@"Enabled"];
    [_soundCheck setState:NSOnState];
    [v addSubview:_soundCheck];

    [self _label:@"Linux Display:" x:0 y:120 w:120 in:v];
    _linuxDisplayPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 120, 180, 24) pullsDown:NO];
    [_linuxDisplayPopup addItemsWithTitles:@[
        @"virtio-vga (recommended)",
        @"virtio-ramfb",
        @"virtio-gpu-pci",
        @"vmware-svga",
        @"VGA",
        @"cirrus-vga"]];
    [v addSubview:_linuxDisplayPopup];

    _devicesStep = [[GSAssistantStep alloc] initWithTitle:@"Devices"
                                              description:@"Configure network, sound and the display card for Linux guests."
                                                     view:v];
    _devicesStep.canProceed = YES;
    return _devicesStep;
}

#pragma mark - Step 4: Summary

- (GSAssistantStep *)_summaryStep
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
    NSTextField *t = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 260, 500, 30)];
    [t setStringValue:@"Review and click Create to finish."];
    [t setBezeled:NO];
    [t setEditable:NO];
    [t setDrawsBackground:NO];
    [v addSubview:t];

    _summaryStep = [[GSAssistantStep alloc] initWithTitle:@"Summary"
                                              description:@"Review your configuration and create the VM."
                                                     view:v];
    _summaryStep.canProceed = YES;
    return _summaryStep;
}

#pragma mark - Helpers

- (void)_label:(NSString *)t x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w in:(NSView *)parent
{
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, w, 22)];
    [l setStringValue:t];
    [l setBezeled:NO];
    [l setEditable:NO];
    [l setDrawsBackground:NO];
    [l setAlignment:NSRightTextAlignment];
    [l setFont:[NSFont systemFontOfSize:12]];
    [parent addSubview:l];
}

- (NSTextField *)_field:(NSRect)frame placeholder:(NSString *)ph
{
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    [f setBezeled:YES];
    [f setBordered:YES];
    [f setEditable:YES];
    [f setFont:[NSFont systemFontOfSize:12]];
    return f;
}

- (NSButton *)_btnWithTitle:(NSString *)t frame:(NSRect)frame action:(SEL)action
{
    NSButton *b = [[NSButton alloc] initWithFrame:frame];
    [b setTitle:t];
    [b setBezelStyle:NSRoundedBezelStyle];
    [b setTarget:self];
    [b setAction:action];
    return b;
}

- (void)_browseDisk
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setTitle:@"Select Disk Image"];
    [p setAllowsMultipleSelection:NO];
    [p setCanChooseDirectories:NO];
    if ([p runModal] == NSOKButton) {
        [_diskField setStringValue:[[p URL] path]];
        [self _updateStorageValidation];
        /* Guess name and arch from path */
        NSString *guessed = [self _guessNameFromPath:[_diskField stringValue]];
        if ([guessed length] > 0 && _nameField) {
            [_nameField setStringValue:guessed];
            [self _updateNameValidation];
        }
        if (_archPopup) {
            NSString *arch = [self _guessArchFromPath:[_diskField stringValue]];
            [_archPopup selectItemAtIndex:[arch isEqualToString:@"aarch64"] ? 1 : 0];
        }
    }
}

- (void)_browseCdrom
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setTitle:@"Select CDROM Image"];
    [p setAllowsMultipleSelection:NO];
    [p setCanChooseDirectories:NO];
    if ([p runModal] == NSOKButton) {
        [_cdField setStringValue:[[p URL] path]];
        [self _updateStorageValidation];
    }
}

#pragma mark - Delegate

- (void)_readValues
{
    if (_nameField && [[_nameField stringValue] length]) _config.name = [_nameField stringValue];
    if (_archPopup) _config.architecture = [[_archPopup titleOfSelectedItem] lowercaseString];
    if (_memField) _config.memorySize = (NSUInteger)[_memField integerValue];
    if (_cpuPopup) _config.cpuCount = (NSUInteger)[[_cpuPopup titleOfSelectedItem] integerValue];
    if (_targetPopup) {
        NSString *s = [_targetPopup titleOfSelectedItem];
        if ([s hasPrefix:@"q35"]) _config.target = @"q35";
        else if ([s hasPrefix:@"pc"]) _config.target = @"pc";
        else if ([s hasPrefix:@"virt"]) _config.target = @"virt";
    }
    if (_diskField && [[_diskField stringValue] length]) _config.diskImagePath = [_diskField stringValue];
    if (_cdField && [[_cdField stringValue] length]) _config.cdromImagePath = [_cdField stringValue];
    if (_netPopup) _config.networkCard = [[_netPopup titleOfSelectedItem] lowercaseString];
    if (_netCheck) _config.networkEnabled = (_netCheck.state == NSOnState);
    if (_soundPopup) _config.soundCard = [[_soundPopup titleOfSelectedItem] lowercaseString];
    if (_soundCheck) _config.soundEnabled = (_soundCheck.state == NSOnState);
    if (_linuxDisplayPopup) {
        NSString *card = [_linuxDisplayPopup titleOfSelectedItem];
        NSRange rec = [card rangeOfString:@" (recommended)"];
        if (rec.location != NSNotFound)
            card = [card substringToIndex:rec.location];
        _config.linuxHostDisplayCard = card;
    }
}

- (void)_buildSummary:(GSAssistantWindow *)window
{
    [self _readValues];
    id<GSAssistantStepProtocol> step = [window.steps objectAtIndex:4];
    NSView *v = [step stepView];
    /* Clear old summary */
    for (NSView *sv in [v subviews]) {
        if ([sv isKindOfClass:[NSTextField class]] && [sv frame].origin.y < 250)
            [sv removeFromSuperview];
    }
    /* Show summary text */
    NSString *disk = [_config.diskImagePath length] ? _config.diskImagePath : @"(none)";
    NSString *cd = [_config.cdromImagePath length] ? _config.cdromImagePath : @"(none)";
    NSString *txt = [NSString stringWithFormat:
        @"Name:       %@\nArch:       %@\nTarget:     %@\n"
        @"Memory:    %lu MB\nCPUs:      %lu\n\n"
        @"Disk:      %@\nCDROM:     %@\n\n"
        @"Network:   %@ (%@)\nSound:     %@ (%@)\n"
        @"Linux GPU: %@",
        _config.name, _config.architecture, _config.target,
        (unsigned long)_config.memorySize, (unsigned long)_config.cpuCount,
        disk, cd,
        _config.networkCard, _config.networkEnabled ? @"on" : @"off",
        _config.soundCard, _config.soundEnabled ? @"on" : @"off",
        _config.linuxHostDisplayCard ?: @"virtio-vga"];

    NSTextField *info = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 20, 500, 220)];
    [info setStringValue:txt];
    [info setBezeled:NO];
    [info setEditable:NO];
    [info setDrawsBackground:NO];
    [info setFont:[NSFont fontWithName:@"Menlo" size:11] ?: [NSFont userFixedPitchFontOfSize:11]];
    [v addSubview:info];
}

- (void)assistantWindow:(GSAssistantWindow *)window didShowStep:(id<GSAssistantStepProtocol>)step
{
    NSInteger idx = [window currentStepIndex];
    if (idx == 0) {
        /* Preload values when editing an existing config */
        if (_isEditing && _config && [_config.name length] > 0) {
            [self _preloadFields];
        }
        [self _updateStorageValidation];
        if ([[_diskField stringValue] length] > 0 || [[_cdField stringValue] length] > 0) {
            _imagesStep.canProceed = YES;
            [_imagesStep.assistantWindow updateNavigationButtons];
        }
    } else if (idx == 4) {
        [self _readValues];
        [self _buildSummary:window];
    }
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window
{
    [self _readValues];

    /* Editing an existing VM: overwrite the bundle in place */
    if (_isEditing && _config.baseURL) {
        NSURL *plistURL = [_config.baseURL URLByAppendingPathComponent:@"config.plist"];
        [_config saveToURL:plistURL error:NULL];
        [_owner loadConfigFromURL:_config.baseURL];
        return;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setTitle:@"Save Virtual Machine"];
    [panel setNameFieldStringValue:[_config.name stringByAppendingString:@".utm"]];
    [panel setCanCreateDirectories:YES];
    if ([panel runModal] != NSOKButton) return;

    NSURL *bundleURL = [panel URL];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtURL:bundleURL withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm createDirectoryAtURL:[bundleURL URLByAppendingPathComponent:@"Images" isDirectory:YES]
 withIntermediateDirectories:YES attributes:nil error:NULL];

    [_config saveToURL:[bundleURL URLByAppendingPathComponent:@"config.plist"] error:NULL];

    /* Load the new bundle and start the VM after the modal loop ends */
    [_owner loadConfigFromURL:bundleURL];
    [_owner performSelector:@selector(startVM) withObject:nil afterDelay:0];
}

- (void)assistantWindowWillClose:(GSAssistantWindow *)window
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)assistantWindowDidCancel:(GSAssistantWindow *)window
{
}

@end
