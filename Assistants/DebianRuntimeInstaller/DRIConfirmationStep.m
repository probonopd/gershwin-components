//
// DRIConfirmationStep.m
// Debian Runtime Installer - Confirmation Step
//

#import "DRIConfirmationStep.h"

@interface DRIConfirmationStep()
@property (nonatomic, strong) NSString *selectedImageURL;
@property (nonatomic, strong) NSString *selectedImageName;
@property (nonatomic, assign) long long selectedImageSize;
@end

@implementation DRIConfirmationStep

- (instancetype)init
{
    if (self = [super init]) {
        NSLog(@"DRIConfirmationStep: init");
        _selectedImageURL = @"";
        _selectedImageName = @"Unknown";
        _selectedImageSize = 0;
    }
    return self;
}

- (NSString *)stepTitle
{
    return NSLocalizedString(@"Confirm Installation", @"");
}

- (NSString *)stepDescription
{
    return NSLocalizedString(@"Review installation details", @"");
}

- (NSView *)stepView
{
    if (_contentView) {
        return _contentView;
    }

    NSLog(@"DRIConfirmationStep: creating stepView");

    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];

    // Summary label
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 172, 322, 18)];
    [titleLabel setStringValue:NSLocalizedString(@"Ready to Install", @"")];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [titleLabel setAlignment:NSTextAlignmentCenter];
    [_contentView addSubview:titleLabel];
    [titleLabel release];

    // Summary view inside card
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 16, 322, 148)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];

    _summaryView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 304, 148)];
    [_summaryView setEditable:NO];
    [_summaryView setFont:[NSFont systemFontOfSize:11]];

    [scrollView setDocumentView:_summaryView];
    [_contentView addSubview:scrollView];

    return _contentView;
}

- (void)stepWillAppear
{
    NSLog(@"DRIConfirmationStep: stepWillAppear");
    [self updateSummary];
}

- (void)stepDidAppear
{
    NSLog(@"DRIConfirmationStep: stepDidAppear");
}

- (BOOL)canContinue
{
    return YES;
}

- (BOOL)canGoBack
{
    return YES;
}

- (NSString *)continueButtonTitle
{
    return NSLocalizedString(@"Install", @"");
}

- (void)setSelectedImageURL:(NSString *)url
{
    _selectedImageURL = url ?: @"";
    NSLog(@"DRIConfirmationStep: set image URL: %@", _selectedImageURL);
    [self updateSummary];
}

- (void)setSelectedImageName:(NSString *)name
{
    _selectedImageName = name ?: @"Unknown";
    NSLog(@"DRIConfirmationStep: set image name: %@", _selectedImageName);
    [self updateSummary];
}

- (void)setSelectedImageSize:(long long)size
{
    _selectedImageSize = size;
    NSLog(@"DRIConfirmationStep: set image size: %lld", size);
    [self updateSummary];
}

- (void)updateSummary
{
    if (!_summaryView) {
        return; // UI not ready yet
    }

    NSLog(@"DRIConfirmationStep: updateSummary");

    NSMutableString *summary = [[NSMutableString alloc] init];

    [summary appendString:@"DEBIAN RUNTIME INSTALLATION SUMMARY\n"];
    [summary appendString:@"=====================================\n\n"];

    [summary appendString:@"Selected Runtime Image:\n"];
    [summary appendFormat:@"• Name: %@\n", _selectedImageName];
    [summary appendFormat:@"• Size: %@\n", [self formatFileSize:_selectedImageSize]];
    if ([_selectedImageURL length] > 0) {
        [summary appendFormat:@"• Source: %@\n", _selectedImageURL];
    }
    [summary appendString:@"\n"];

    [summary appendString:@"What will be installed:\n"];
    [summary appendString:@"• Debian Linux Runtime Image\n"];
    [summary appendString:@"• Service script for automatic startup\n"];
    [summary appendString:@"• Integration with FreeBSD's rc system\n"];
    [summary appendString:@"• Linux compatibility layer configuration\n\n"];

    [summary appendString:@"Installation details:\n"];
    [summary appendString:@"• Destination: /compat/debian.img\n"];
    [summary appendString:@"• Service script: /usr/local/etc/rc.d/debian\n"];
    [summary appendString:@"• RC configuration: /etc/rc.conf\n"];
    [summary appendString:@"• Mount point: /compat/debian\n\n"];

    [summary appendString:@"System requirements:\n"];
    [summary appendString:@"• FreeBSD system with Linux compatibility layer\n"];
    [summary appendString:@"• Internet connection for downloading\n"];
    [summary appendString:@"• Root privileges (application running as root)\n"];
    [summary appendFormat:@"• At least %@ free space in /compat\n\n", [self formatFileSize:_selectedImageSize + 100*1024*1024]];

    [summary appendString:@"IMPORTANT WARNINGS:\n"];
    [summary appendString:@"• This installation requires root privileges\n"];
    [summary appendString:@"• You will be prompted for administrator password\n"];
    [summary appendString:@"• Any existing Linux runtime will be replaced\n"];
    [summary appendString:@"• The download may take several minutes\n"];
    [summary appendString:@"• Installation will modify system configuration\n\n"];

    [summary appendString:@"Installation process:\n"];
    [summary appendString:@"1. Download runtime image from source\n"];
    [summary appendString:@"2. Verify Linux compatibility layer\n"];
    [summary appendString:@"3. Create /compat directory structure\n"];
    [summary appendString:@"4. Install runtime image\n"];
    [summary appendString:@"5. Configure service scripts\n"];
    [summary appendString:@"6. Enable automatic startup\n\n"];

    [summary appendString:@"After installation:\n"];
    [summary appendString:@"• Linux applications will be able to run\n"];
    [summary appendString:@"• The runtime will start automatically on boot\n"];
    [summary appendString:@"• You can manage it using 'service debian start/stop'\n"];
    [summary appendString:@"• Runtime will be mounted at /compat/debian\n\n"];

    [summary appendString:@"Click 'Install' to begin the installation process."];

    [_summaryView setString:summary];

    // Scroll to top
    [_summaryView scrollRangeToVisible:NSMakeRange(0, 0)];
}

- (NSString *)formatFileSize:(long long)bytes
{
    if (bytes > 1000000000) {
        return [NSString stringWithFormat:@"%.1f GB", bytes / 1000000000.0];
    } else if (bytes > 1000000) {
        return [NSString stringWithFormat:@"%.1f MB", bytes / 1000000.0];
    } else if (bytes > 1000) {
        return [NSString stringWithFormat:@"%.1f KB", bytes / 1000.0];
    } else {
        return [NSString stringWithFormat:@"%lld bytes", bytes];
    }
}

@end
