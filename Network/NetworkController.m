/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Network Controller Implementation
 */

#import "NetworkController.h"
#import "NMBackend.h"
#import "BSDBackend.h"
#import "CaptivePortalDetector.h"
#include <sys/utsname.h>
#if defined(__FreeBSD__) || defined(__DragonFly__)
#include <sys/sysctl.h>
#endif

// Layout constants following Eau Theme HIG (AppearanceMetrics.h)
static const CGFloat kWindowWidth = 668;
static const CGFloat kWindowHeight = 400;
static const CGFloat kServiceListWidth = 180;

// HIG-compliant margins
static const CGFloat kContentTopMargin = 15.0;
static const CGFloat kContentSideMargin = 24.0;
static const CGFloat kContentBottomMargin = 20.0;
static const CGFloat kSpace8 = 8.0;
static const CGFloat kSpace12 = 12.0;
static const CGFloat kSpace20 = 20.0;

// HIG-compliant control sizes
static const CGFloat kButtonHeight = 20.0;
static const CGFloat kButtonMinWidth = 69.0;
static const CGFloat kFieldHeight = 22.0;
static const CGFloat kLabelWidth = 110;
static const CGFloat kStatusAreaHeight = 60;

@interface NetworkController ()
- (void)updateClonedMacPopup;
@end

@implementation NetworkController

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        interfaces = [[NSMutableArray alloc] init];
        wlanNetworks = [[NSMutableArray alloc] init];
        selectedInterface = nil;
        selectedWLANNetwork = nil;
        isEditing = NO;
        
        // Initialize the backend based on OS
        // NOTE: uname() is unreliable on FreeBSD with linux_enable="YES"
        // because the Linux ABI compatibility layer makes it return "Linux".
        // Use sysctlbyname or file-based detection instead.
        BOOL isFreeBSD = NO;

#if defined(__FreeBSD__) || defined(__DragonFly__)
        {
            char ostype[64] = {0};
            size_t len = sizeof(ostype) - 1;
            if (sysctlbyname("kern.ostype", ostype, &len, NULL, 0) == 0) {
                if (strcmp(ostype, "FreeBSD") == 0 ||
                    strcmp(ostype, "DragonFly") == 0) {
                    isFreeBSD = YES;
                }
            }
        }
#endif

        if (!isFreeBSD) {
            /* File-based fallback: sysrc(8) is FreeBSD-specific */
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm isExecutableFileAtPath:@"/usr/sbin/sysrc"]) {
                isFreeBSD = YES;
            }
        }

        if (!isFreeBSD) {
            /* Last resort: uname (unreliable with Linux ABI compat) */
            struct utsname uts;
            if (uname(&uts) == 0 && strcmp(uts.sysname, "FreeBSD") == 0) {
                isFreeBSD = YES;
            }
        }

        if (isFreeBSD) {
            NSDebugLLog(@"gwcomp", @"[Network] Detected FreeBSD, using BSD backend");
            backend = [[BSDBackend alloc] init];
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] Detected Linux/other, using NetworkManager backend");
            backend = [[NMBackend alloc] init];
        }
        [backend setDelegate:self];
        
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] NetworkManager backend is not available");
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] Using %@ version %@", [backend backendName], [backend backendVersion]);
        }
    }
    return self;
}

- (void)dealloc
{
    [self stopWLANRefreshTimer];
    if (refreshTimer) {
        [refreshTimer invalidate];
        [refreshTimer release];
    }
    [(id)backend release];
    [interfaces release];
    [wlanNetworks release];
    [mainView release];
    [advancedPanel release];
    [passwordPanel release];
    [joinNetworkPanel release];
    [pendingNetwork release];
    [serviceContextMenu release];
    [super dealloc];
}

#pragma mark - Main View Creation

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }
    
    // Use dynamic width based on what SystemPreferences provides
    // Default to kWindowWidth if no parent view exists yet
    CGFloat actualWidth = kWindowWidth;
    CGFloat actualHeight = kWindowHeight;
    
    mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, actualWidth, actualHeight)];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    // Check if backend is available
    if (![backend isAvailable]) {
        [self createUnavailableView];
        return mainView;
    }
    
    // Get actual dimensions from mainView bounds
    NSRect viewBounds = [mainView bounds];
    CGFloat viewWidth = NSWidth(viewBounds);
    CGFloat viewHeight = NSHeight(viewBounds);
    
    // Create the split view area (HIG spacing)
    CGFloat splitTop = viewHeight - kContentTopMargin - 40;
    CGFloat splitHeight = splitTop - kContentBottomMargin - 30; // Leave room for buttons at bottom
    
    // Service list on the left
    [self createServiceListViewWithFrame:NSMakeRect(kContentSideMargin, kContentBottomMargin + 30, 
                                                     kServiceListWidth, splitHeight)];
    
    // Detail view on the right (8px gap between panels)
    CGFloat detailX = kContentSideMargin + kServiceListWidth + kSpace8;
    CGFloat detailWidth = viewWidth - detailX - kContentSideMargin;
    [self createDetailViewWithFrame:NSMakeRect(detailX, kContentBottomMargin + 30, 
                                                detailWidth, splitHeight)];
    
    // Bottom buttons
    [self createBottomButtons];
    
    // Create panels
    [self createPasswordPanel];
    [self createAdvancedPanel];
    
    // Initial data load
    [self refreshInterfaces:nil];
    
    return mainView;
}

- (void)createUnavailableView
{
    CGFloat viewWidth = NSWidth([mainView bounds]);
    CGFloat viewHeight = NSHeight([mainView bounds]);
    
    NSTextField *errorLabel = [[NSTextField alloc] initWithFrame:
                               NSMakeRect(kContentSideMargin, viewHeight/2 - 40, viewWidth - kContentSideMargin*2, 80)];
    [errorLabel setStringValue:@"Network configuration is not available.\n\n"
                                "NetworkManager is required but was not found.\n"
                                "Please install the 'network-manager' package."];
    [errorLabel setBezeled:NO];
    [errorLabel setDrawsBackground:NO];
    [errorLabel setEditable:NO];
    [errorLabel setSelectable:NO];
    [errorLabel setFont:[NSFont systemFontOfSize:13]];
    [errorLabel setAlignment:NSCenterTextAlignment];
    [mainView addSubview:errorLabel];
    [errorLabel release];
}

#pragma mark - Service List View

- (void)createServiceListViewWithFrame:(NSRect)frame
{
    // Container with bezel border (standard appearance, no dark colors)
    NSBox *serviceBox = [[NSBox alloc] initWithFrame:frame];
    [serviceBox setBoxType:NSBoxCustom];
    [serviceBox setBorderType:NSBezelBorder];
    [serviceBox setTitlePosition:NSNoTitle];
    [serviceBox setContentViewMargins:NSMakeSize(0, 0)];
    [mainView addSubview:serviceBox];
    [serviceBox release];
    
    // Table view for services (HIG: standard row height)
    NSRect tableFrame = NSMakeRect(0, 25, frame.size.width, frame.size.height - 25);
    serviceScrollView = [[NSScrollView alloc] initWithFrame:tableFrame];
    [serviceScrollView setHasVerticalScroller:YES];
    [serviceScrollView setHasHorizontalScroller:NO];
    [serviceScrollView setBorderType:NSBezelBorder];
    [serviceScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    serviceTable = [[NSTableView alloc] initWithFrame:[[serviceScrollView contentView] bounds]];
    [serviceTable setDelegate:self];
    [serviceTable setDataSource:self];
    [serviceTable setRowHeight:36];
    [serviceTable setHeaderView:nil];
    [serviceTable setAllowsEmptySelection:NO];
    [serviceTable setAllowsMultipleSelection:NO];
    [serviceTable setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    
    NSTableColumn *iconColumn = [[NSTableColumn alloc] initWithIdentifier:@"icon"];
    [iconColumn setWidth:32];
    [iconColumn setMinWidth:32];
    [iconColumn setMaxWidth:32];
    [iconColumn setEditable:NO];
    [serviceTable addTableColumn:iconColumn];
    [iconColumn release];
    
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [nameColumn setWidth:frame.size.width - 40];
    [nameColumn setMinWidth:100];
    [nameColumn setEditable:NO];
    [nameColumn setResizingMask:NSTableColumnAutoresizingMask];
    [serviceTable addTableColumn:nameColumn];
    [nameColumn release];
    
    [serviceScrollView setDocumentView:serviceTable];
    [serviceBox addSubview:serviceScrollView];
    
    // Create context menu for table
    serviceContextMenu = [[NSMenu alloc] initWithTitle:@"Service"];
    [serviceContextMenu setDelegate:self];
    NSMenuItem *enableItem = [[NSMenuItem alloc] initWithTitle:@"Enable" 
                                                         action:@selector(enableInterface:) 
                                                  keyEquivalent:@""];
    [enableItem setTarget:self];
    [serviceContextMenu addItem:enableItem];
    [enableItem release];
    
    NSMenuItem *disableItem = [[NSMenuItem alloc] initWithTitle:@"Disable" 
                                                          action:@selector(disableInterface:) 
                                                   keyEquivalent:@""];
    [disableItem setTarget:self];
    [serviceContextMenu addItem:disableItem];
    [disableItem release];
    
    [serviceTable setMenu:serviceContextMenu];
    
    // Bottom button bar with enable/disable buttons
    CGFloat buttonY = 1;
    CGFloat buttonWidth = 80;
    CGFloat buttonSpacing = 8;
    
    enableButton = [[NSButton alloc] initWithFrame:
                    NSMakeRect(buttonSpacing, buttonY, buttonWidth, kButtonHeight)];
    [enableButton setBezelStyle:NSRoundedBezelStyle];
    [enableButton setTitle:@"Enable"];
    [enableButton setFont:[NSFont systemFontOfSize:12]];
    [enableButton setTarget:self];
    [enableButton setAction:@selector(enableInterface:)];
    [enableButton setEnabled:NO];
    [serviceBox addSubview:enableButton];
    
    disableButton = [[NSButton alloc] initWithFrame:
                     NSMakeRect(buttonSpacing * 2 + buttonWidth, buttonY, buttonWidth, kButtonHeight)];
    [disableButton setBezelStyle:NSRoundedBezelStyle];
    [disableButton setTitle:@"Disable"];
    [disableButton setFont:[NSFont systemFontOfSize:12]];
    [disableButton setTarget:self];
    [disableButton setAction:@selector(disableInterface:)];
    [disableButton setEnabled:NO];
    [serviceBox addSubview:disableButton];
}

#pragma mark - Detail View

- (void)createDetailViewWithFrame:(NSRect)frame
{
    // Container with border - use standard bezel for Eau theme compliance
    NSBox *detailBox = [[NSBox alloc] initWithFrame:frame];
    [detailBox setBoxType:NSBoxCustom];
    [detailBox setBorderType:NSBezelBorder];
    [detailBox setTitlePosition:NSNoTitle];
    [detailBox setContentViewMargins:NSMakeSize(0, 0)];
    [mainView addSubview:detailBox];
    [detailBox release];
    
    detailView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    [detailBox setContentView:detailView];
    
    // Status area at top
    [self createStatusAreaWithFrame:NSMakeRect(0, frame.size.height - kStatusAreaHeight - 10, 
                                                frame.size.width, kStatusAreaHeight)];
    
    // Tab view for different connection types
    CGFloat tabY = kSpace8;
    CGFloat tabHeight = frame.size.height - kStatusAreaHeight - kSpace20;
    
    detailTabView = [[NSTabView alloc] initWithFrame:
                     NSMakeRect(kSpace12, tabY, frame.size.width - kSpace12 * 2, tabHeight)];
    [detailTabView setTabViewType:NSTopTabsBezelBorder];
    [detailTabView setFont:[NSFont systemFontOfSize:11]];
    [detailTabView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    // TCP/IP tab
    NSTabViewItem *tcpipTab = [[NSTabViewItem alloc] initWithIdentifier:@"tcpip"];
    [tcpipTab setLabel:@"TCP/IP"];
    [self createTCPIPViewForTab:tcpipTab];
    [detailTabView addTabViewItem:tcpipTab];
    [tcpipTab release];
    
    // DNS tab
    NSTabViewItem *dnsTab = [[NSTabViewItem alloc] initWithIdentifier:@"dns"];
    [dnsTab setLabel:@"DNS"];
    [self createDNSViewForTab:dnsTab];
    [detailTabView addTabViewItem:dnsTab];
    [dnsTab release];
    
    // WLAN tab is added dynamically in updateDetailView when showing wireless interfaces
    
    [detailView addSubview:detailTabView];
}

- (void)createStatusAreaWithFrame:(NSRect)frame
{
    NSView *statusView = [[NSView alloc] initWithFrame:frame];
    [statusView setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    
    // Status icon
    statusIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(kSpace12, kSpace12, 48, 48)];
    [statusIcon setImageScaling:NSImageScaleProportionallyUpOrDown];
    [statusView addSubview:statusIcon];
    
    // Status label
    statusLabel = [[NSTextField alloc] initWithFrame:
                   NSMakeRect(70, 35, frame.size.width - 90, 20)];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [statusLabel setStringValue:@""];
    [statusView addSubview:statusLabel];
    
    // Status detail label
    statusDetailLabel = [[NSTextField alloc] initWithFrame:
                         NSMakeRect(70, 10, frame.size.width - 90, 30)];
    [statusDetailLabel setBezeled:NO];
    [statusDetailLabel setDrawsBackground:NO];
    [statusDetailLabel setEditable:NO];
    [statusDetailLabel setSelectable:YES];
    [statusDetailLabel setFont:[NSFont systemFontOfSize:11]];
    [statusDetailLabel setTextColor:[NSColor colorWithCalibratedWhite:0.4 alpha:1.0]];
    [statusDetailLabel setStringValue:@""];
    [statusView addSubview:statusDetailLabel];
    
    [detailView addSubview:statusView];
    [statusView release];
}

- (void)createTCPIPViewForTab:(NSTabViewItem *)tab
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 220)];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    CGFloat y = 200;
    CGFloat labelX = 10;
    CGFloat fieldX = kLabelWidth + 8;
    CGFloat fieldWidth = 200;
    
    // Configure IPv4 popup
    NSTextField *configLabel = [[NSTextField alloc] initWithFrame:
                                 NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [configLabel setStringValue:@"Configure IPv4:"];
    [configLabel setBezeled:NO];
    [configLabel setDrawsBackground:NO];
    [configLabel setEditable:NO];
    [configLabel setAlignment:NSRightTextAlignment];
    [configLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:configLabel];
    [configLabel release];
    
    configureIPv4Popup = [[NSPopUpButton alloc] initWithFrame:
                          NSMakeRect(fieldX, y, fieldWidth, 26)];
    [configureIPv4Popup addItemWithTitle:@"Using DHCP"];
    [configureIPv4Popup addItemWithTitle:@"Manually"];
    [configureIPv4Popup addItemWithTitle:@"Off"];
    [configureIPv4Popup setTarget:self];
    [configureIPv4Popup setAction:@selector(configureIPv4Changed:)];
    [configureIPv4Popup setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:configureIPv4Popup];
    
    y -= 28;
    
    // IP Address
    NSTextField *ipLabel = [[NSTextField alloc] initWithFrame:
                            NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [ipLabel setStringValue:@"IP Address:"];
    [ipLabel setBezeled:NO];
    [ipLabel setDrawsBackground:NO];
    [ipLabel setEditable:NO];
    [ipLabel setAlignment:NSRightTextAlignment];
    [ipLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:ipLabel];
    [ipLabel release];
    
    ipAddressField = [[NSTextField alloc] initWithFrame:
                      NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [ipAddressField setEditable:NO];
    [ipAddressField setPlaceholderString:@""];
    [ipAddressField setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:ipAddressField];
    
    y -= 24;
    
    // Subnet Mask
    NSTextField *subnetLabel = [[NSTextField alloc] initWithFrame:
                                NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [subnetLabel setStringValue:@"Subnet Mask:"];
    [subnetLabel setBezeled:NO];
    [subnetLabel setDrawsBackground:NO];
    [subnetLabel setEditable:NO];
    [subnetLabel setAlignment:NSRightTextAlignment];
    [subnetLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:subnetLabel];
    [subnetLabel release];
    
    subnetMaskField = [[NSTextField alloc] initWithFrame:
                       NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [subnetMaskField setEditable:NO];
    [subnetMaskField setPlaceholderString:@""];
    [subnetMaskField setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:subnetMaskField];
    
    y -= 24;
    
    // Router
    NSTextField *routerLabel = [[NSTextField alloc] initWithFrame:
                                NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [routerLabel setStringValue:@"Router:"];
    [routerLabel setBezeled:NO];
    [routerLabel setDrawsBackground:NO];
    [routerLabel setEditable:NO];
    [routerLabel setAlignment:NSRightTextAlignment];
    [routerLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:routerLabel];
    [routerLabel release];
    
    routerField = [[NSTextField alloc] initWithFrame:
                   NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [routerField setEditable:NO];
    [routerField setPlaceholderString:@""];
    [routerField setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:routerField];
    
    y -= 28;
    
    // Configure IPv6 popup
    NSTextField *config6Label = [[NSTextField alloc] initWithFrame:
                                 NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [config6Label setStringValue:@"Configure IPv6:"];
    [config6Label setBezeled:NO];
    [config6Label setDrawsBackground:NO];
    [config6Label setEditable:NO];
    [config6Label setAlignment:NSRightTextAlignment];
    [config6Label setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:config6Label];
    [config6Label release];
    
    configureIPv6Popup = [[NSPopUpButton alloc] initWithFrame:
                          NSMakeRect(fieldX, y, fieldWidth, 26)];
    [configureIPv6Popup addItemWithTitle:@"Automatically"];
    [configureIPv6Popup addItemWithTitle:@"Manually"];
    [configureIPv6Popup addItemWithTitle:@"Link-local only"];
    [configureIPv6Popup addItemWithTitle:@"Off"];
    [configureIPv6Popup setTarget:self];
    [configureIPv6Popup setAction:@selector(configureIPv6Changed:)];
    [configureIPv6Popup setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:configureIPv6Popup];
    
    y -= 28;
    
    // IPv6 Address (display only for now)
    NSTextField *ipv6Label = [[NSTextField alloc] initWithFrame:
                              NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [ipv6Label setStringValue:@"IPv6 Address:"];
    [ipv6Label setBezeled:NO];
    [ipv6Label setDrawsBackground:NO];
    [ipv6Label setEditable:NO];
    [ipv6Label setAlignment:NSRightTextAlignment];
    [ipv6Label setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:ipv6Label];
    [ipv6Label release];
    
    ipv6AddressField = [[NSTextField alloc] initWithFrame:
                        NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [ipv6AddressField setEditable:NO];
    [ipv6AddressField setPlaceholderString:@""];
    [ipv6AddressField setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:ipv6AddressField];
    
    y -= 28;
    
    // Renew DHCP Lease button
    dhcpLeaseButton = [[NSButton alloc] initWithFrame:
                       NSMakeRect(fieldX, y, 150, kButtonHeight)];
    [dhcpLeaseButton setBezelStyle:NSRoundedBezelStyle];
    [dhcpLeaseButton setTitle:@"Renew DHCP Lease"];
    [dhcpLeaseButton setTarget:self];
    [dhcpLeaseButton setAction:@selector(renewDHCPLease:)];
    [dhcpLeaseButton setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:dhcpLeaseButton];
    
    [tab setView:view];
    [view release];
}

- (void)createDNSViewForTab:(NSTabViewItem *)tab
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 180)];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    CGFloat y = 150;
    CGFloat labelX = 10;
    CGFloat fieldX = kLabelWidth + 8;
    CGFloat fieldWidth = 250;
    
    // DNS Servers
    NSTextField *dnsLabel = [[NSTextField alloc] initWithFrame:
                             NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [dnsLabel setStringValue:@"DNS Servers:"];
    [dnsLabel setBezeled:NO];
    [dnsLabel setDrawsBackground:NO];
    [dnsLabel setEditable:NO];
    [dnsLabel setAlignment:NSRightTextAlignment];
    [dnsLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:dnsLabel];
    [dnsLabel release];
    
    dnsServersField = [[NSTextField alloc] initWithFrame:
                       NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [dnsServersField setEditable:NO];
    [dnsServersField setPlaceholderString:@"e.g., 8.8.8.8, 8.8.4.4"];
    [dnsServersField setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:dnsServersField];
    
    y -= 24;
    
    // Search Domains
    NSTextField *searchLabel = [[NSTextField alloc] initWithFrame:
                                NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [searchLabel setStringValue:@"Search Domains:"];
    [searchLabel setBezeled:NO];
    [searchLabel setDrawsBackground:NO];
    [searchLabel setEditable:NO];
    [searchLabel setAlignment:NSRightTextAlignment];
    [searchLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:searchLabel];
    [searchLabel release];
    
    searchDomainsField = [[NSTextField alloc] initWithFrame:
                          NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [searchDomainsField setEditable:NO];
    [searchDomainsField setPlaceholderString:@"e.g., local, home"];
    [searchDomainsField setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:searchDomainsField];
    
    [tab setView:view];
    [view release];
}

- (void)createWLANViewForTab:(NSTabViewItem *)tab
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    wlanView = view;
    
    // WLAN power button
    wlanPowerButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 170, 130, kButtonHeight)];
    [wlanPowerButton setBezelStyle:NSRoundedBezelStyle];
    [wlanPowerButton setTitle:@"Turn WLAN Off"];
    [wlanPowerButton setTarget:self];
    [wlanPowerButton setAction:@selector(toggleWLANPower:)];
    [wlanPowerButton setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:wlanPowerButton];
    
    // Scan progress indicator
    scanProgress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(150, 173, 16, 16)];
    [scanProgress setStyle:NSProgressIndicatorSpinningStyle];
    [scanProgress setDisplayedWhenStopped:NO];
    [scanProgress setControlSize:NSSmallControlSize];
    [scanProgress setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:scanProgress];
    
    // Network Name label
    NSTextField *networkLabel = [[NSTextField alloc] initWithFrame:
                                  NSMakeRect(10, 145, 100, kFieldHeight)];
    [networkLabel setStringValue:@"Network Name:"];
    [networkLabel setBezeled:NO];
    [networkLabel setDrawsBackground:NO];
    [networkLabel setEditable:NO];
    [networkLabel setFont:[NSFont systemFontOfSize:11]];
    [networkLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:networkLabel];
    [networkLabel release];
    
    // WLAN network table
    wlanScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 35, 380, 105)];
    [wlanScrollView setHasVerticalScroller:YES];
    [wlanScrollView setHasHorizontalScroller:NO];
    [wlanScrollView setBorderType:NSBezelBorder];
    [wlanScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    wlanTable = [[NSTableView alloc] initWithFrame:[[wlanScrollView contentView] bounds]];
    [wlanTable setDelegate:self];
    [wlanTable setDataSource:self];
    [wlanTable setRowHeight:17];  // Smaller row height for compact display
    [wlanTable setAllowsEmptySelection:YES];
    [wlanTable setDoubleAction:@selector(wlanTableDoubleClicked:)];
    [wlanTable setTarget:self];
    [wlanTable setFont:[NSFont systemFontOfSize:11]];  // Use small font
    [wlanTable setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    NSTableColumn *signalColumn = [[NSTableColumn alloc] initWithIdentifier:@"signal"];
    [signalColumn setWidth:24];
    [signalColumn setEditable:NO];
    [[signalColumn headerCell] setStringValue:@""];
    [wlanTable addTableColumn:signalColumn];
    [signalColumn release];
    
    NSTableColumn *ssidColumn = [[NSTableColumn alloc] initWithIdentifier:@"ssid"];
    [ssidColumn setWidth:200];
    [ssidColumn setEditable:NO];
    [[ssidColumn headerCell] setStringValue:@"Network"];
    [[ssidColumn headerCell] setFont:[NSFont systemFontOfSize:11]];
    [wlanTable addTableColumn:ssidColumn];
    [ssidColumn release];
    
    NSTableColumn *securityColumn = [[NSTableColumn alloc] initWithIdentifier:@"security"];
    [securityColumn setWidth:80];
    [securityColumn setEditable:NO];
    [[securityColumn headerCell] setStringValue:@"Security"];
    [[securityColumn headerCell] setFont:[NSFont systemFontOfSize:11]];
    [wlanTable addTableColumn:securityColumn];
    [securityColumn release];
    
    NSTableColumn *statusColumn = [[NSTableColumn alloc] initWithIdentifier:@"status"];
    [statusColumn setWidth:60];
    [statusColumn setEditable:NO];
    [[statusColumn headerCell] setStringValue:@""];
    [wlanTable addTableColumn:statusColumn];
    [statusColumn release];
    
    [wlanScrollView setDocumentView:wlanTable];
    [view addSubview:wlanScrollView];
    
    // Bottom buttons
    joinNetworkButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 5, 100, kButtonHeight)];
    [joinNetworkButton setBezelStyle:NSRoundedBezelStyle];
    [joinNetworkButton setTitle:@"Join Network"];
    [joinNetworkButton setTarget:self];
    [joinNetworkButton setAction:@selector(joinNetwork:)];
    [joinNetworkButton setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:joinNetworkButton];
    
    disconnectButton = [[NSButton alloc] initWithFrame:NSMakeRect(115, 5, 90, kButtonHeight)];
    [disconnectButton setBezelStyle:NSRoundedBezelStyle];
    [disconnectButton setTitle:@"Disconnect"];
    [disconnectButton setTarget:self];
    [disconnectButton setAction:@selector(disconnectWLAN:)];
    [disconnectButton setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:disconnectButton];
    
    // MAC Address cloning popup
    clonedMacLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(210, 8, 55, kFieldHeight)];
    [clonedMacLabel setStringValue:@"MAC:"];
    [clonedMacLabel setBezeled:NO];
    [clonedMacLabel setDrawsBackground:NO];
    [clonedMacLabel setEditable:NO];
    [clonedMacLabel setFont:[NSFont systemFontOfSize:11]];
    [clonedMacLabel setAutoresizingMask:NSViewMinXMargin];
    [view addSubview:clonedMacLabel];
    [clonedMacLabel release];

    clonedMacPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(255, 5, 135, kButtonHeight)];
    [[clonedMacPopup menu] removeAllItems];
    [clonedMacPopup addItemWithTitle:@"Default (Permanent)"];
    [[clonedMacPopup lastItem] setRepresentedObject:@"permanent"];
    [clonedMacPopup addItemWithTitle:@"Random"];
    [[clonedMacPopup lastItem] setRepresentedObject:@"random"];
    [clonedMacPopup addItemWithTitle:@"Stable"];
    [[clonedMacPopup lastItem] setRepresentedObject:@"stable"];
    [clonedMacPopup addItemWithTitle:@"Preserve"];
    [[clonedMacPopup lastItem] setRepresentedObject:@"preserve"];
    [clonedMacPopup setTarget:self];
    [clonedMacPopup setAction:@selector(clonedMacChanged:)];
    [clonedMacPopup setAutoresizingMask:NSViewMinXMargin];
    [clonedMacPopup setEnabled:NO];
    [view addSubview:clonedMacPopup];
    [clonedMacPopup release];
    
    [tab setView:view];
}

#pragma mark - Bottom Buttons

- (void)createBottomButtons
{
    CGFloat y = kSpace8;
    CGFloat buttonWidth = kButtonMinWidth + 11; // HIG min width + some extra
    CGFloat viewWidth = NSWidth([mainView bounds]);
    
    // Apply button
    applyButton = [[NSButton alloc] initWithFrame:
                   NSMakeRect(viewWidth - kContentSideMargin - buttonWidth, y, buttonWidth, kButtonHeight)];
    [applyButton setBezelStyle:NSRoundedBezelStyle];
    [applyButton setTitle:@"Apply"];
    [applyButton setTarget:self];
    [applyButton setAction:@selector(applyChanges:)];
    [applyButton setEnabled:NO];
    [applyButton setAutoresizingMask:NSViewMinXMargin];
    [mainView addSubview:applyButton];
    
    // Revert button
    NSButton *revertButton = [[NSButton alloc] initWithFrame:
                              NSMakeRect(viewWidth - kContentSideMargin - buttonWidth * 2 - kSpace12, y, buttonWidth, kButtonHeight)];
    [revertButton setBezelStyle:NSRoundedBezelStyle];
    [revertButton setTitle:@"Revert"];
    [revertButton setTarget:self];
    [revertButton setAction:@selector(revertChanges:)];
    [revertButton setEnabled:NO];
    [revertButton setAutoresizingMask:NSViewMinXMargin];
    [mainView addSubview:revertButton];
    [revertButton release];
}

#pragma mark - Password Panel

- (void)createPasswordPanel
{
    passwordPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 180)
                                               styleMask:NSTitledWindowMask
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES];
    [passwordPanel setTitle:@"Enter Password"];
    
    NSView *content = [passwordPanel contentView];
    
    // Icon
    NSImageView *lockIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 100, 64, 64)];
    [lockIcon setImage:[NSImage imageNamed:@"NSLockLockedTemplate"]];
    [lockIcon setImageScaling:NSImageScaleProportionallyUpOrDown];
    [content addSubview:lockIcon];
    [lockIcon release];
    
    // SSID label
    passwordSSIDLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(95, 140, 285, 22)];
    [passwordSSIDLabel setBezeled:NO];
    [passwordSSIDLabel setDrawsBackground:NO];
    [passwordSSIDLabel setEditable:NO];
    [passwordSSIDLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [content addSubview:passwordSSIDLabel];
    
    // Description
    NSTextField *descLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(95, 110, 285, 30)];
    [descLabel setStringValue:@"Enter the password for this WLAN network."];
    [descLabel setBezeled:NO];
    [descLabel setDrawsBackground:NO];
    [descLabel setEditable:NO];
    [descLabel setFont:[NSFont systemFontOfSize:11]];
    [content addSubview:descLabel];
    [descLabel release];
    
    // Password label
    NSTextField *pwLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(95, 75, 70, 20)];
    [pwLabel setStringValue:@"Password:"];
    [pwLabel setBezeled:NO];
    [pwLabel setDrawsBackground:NO];
    [pwLabel setEditable:NO];
    [pwLabel setAlignment:NSRightTextAlignment];
    [content addSubview:pwLabel];
    [pwLabel release];
    
    // Password field
    passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(170, 73, 210, 24)];
    [content addSubview:passwordField];
    
    // Remember checkbox
    rememberPasswordCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(170, 45, 200, 20)];
    [rememberPasswordCheckbox setButtonType:NSSwitchButton];
    [rememberPasswordCheckbox setTitle:@"Remember this network"];
    [rememberPasswordCheckbox setState:NSOnState];
    [content addSubview:rememberPasswordCheckbox];
    
    // Buttons
    passwordCancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(220, 10, 80, 28)];
    [passwordCancelButton setBezelStyle:NSRoundedBezelStyle];
    [passwordCancelButton setTitle:@"Cancel"];
    [passwordCancelButton setTarget:self];
    [passwordCancelButton setAction:@selector(passwordCancel:)];
    [passwordCancelButton setKeyEquivalent:@"\033"]; // Escape
    [content addSubview:passwordCancelButton];
    
    passwordConnectButton = [[NSButton alloc] initWithFrame:NSMakeRect(305, 10, 80, 28)];
    [passwordConnectButton setBezelStyle:NSRoundedBezelStyle];
    [passwordConnectButton setTitle:@"Join"];
    [passwordConnectButton setTarget:self];
    [passwordConnectButton setAction:@selector(passwordConnect:)];
    [passwordConnectButton setKeyEquivalent:@"\r"]; // Return
    [content addSubview:passwordConnectButton];
}

#pragma mark - Join Other Network Panel

- (void)createJoinNetworkPanel
{
    joinNetworkPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 350, 140)
                                                  styleMask:NSTitledWindowMask
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
    [joinNetworkPanel setTitle:@"Join Other Network"];
    
    NSView *content = [joinNetworkPanel contentView];
    
    // Network name label
    NSTextField *nameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 100, 100, 20)];
    [nameLabel setStringValue:@"Network Name:"];
    [nameLabel setBezeled:NO];
    [nameLabel setDrawsBackground:NO];
    [nameLabel setEditable:NO];
    [nameLabel setAlignment:NSRightTextAlignment];
    [content addSubview:nameLabel];
    [nameLabel release];
    
    // Network name field
    joinNetworkSSIDField = [[NSTextField alloc] initWithFrame:NSMakeRect(125, 98, 205, 24)];
    [joinNetworkSSIDField setPlaceholderString:@"SSID"];
    [content addSubview:joinNetworkSSIDField];
    
    // Security label
    NSTextField *secLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 65, 100, 20)];
    [secLabel setStringValue:@"Security:"];
    [secLabel setBezeled:NO];
    [secLabel setDrawsBackground:NO];
    [secLabel setEditable:NO];
    [secLabel setAlignment:NSRightTextAlignment];
    [content addSubview:secLabel];
    [secLabel release];
    
    // Security popup
    joinNetworkSecurityPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(125, 62, 205, 26)];
    [joinNetworkSecurityPopup addItemWithTitle:@"None"];
    [joinNetworkSecurityPopup addItemWithTitle:@"WPA/WPA2 Personal"];
    [joinNetworkSecurityPopup addItemWithTitle:@"WPA2/WPA3 Personal"];
    [joinNetworkSecurityPopup addItemWithTitle:@"WPA Enterprise"];
    [content addSubview:joinNetworkSecurityPopup];
    
    // Cancel button
    NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(170, 15, 80, 28)];
    [cancelBtn setBezelStyle:NSRoundedBezelStyle];
    [cancelBtn setTitle:@"Cancel"];
    [cancelBtn setTarget:self];
    [cancelBtn setAction:@selector(joinOtherNetworkCancel:)];
    [cancelBtn setKeyEquivalent:@"\033"]; // Escape
    [content addSubview:cancelBtn];
    [cancelBtn release];
    
    // Join button
    NSButton *joinBtn = [[NSButton alloc] initWithFrame:NSMakeRect(255, 15, 80, 28)];
    [joinBtn setBezelStyle:NSRoundedBezelStyle];
    [joinBtn setTitle:@"Join"];
    [joinBtn setTarget:self];
    [joinBtn setAction:@selector(joinOtherNetworkConfirm:)];
    [joinBtn setKeyEquivalent:@"\r"]; // Return
    [content addSubview:joinBtn];
    [joinBtn release];
}

#pragma mark - Advanced Panel

- (void)createAdvancedPanel
{
    advancedPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 550, 400)
                                               styleMask:NSTitledWindowMask
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES];
    [advancedPanel setTitle:@"Advanced"];
    
    NSView *content = [advancedPanel contentView];
    
    advancedTabView = [[NSTabView alloc] initWithFrame:NSMakeRect(10, 50, 530, 340)];
    
    // TCP/IP tab
    NSTabViewItem *tcpipTab = [[NSTabViewItem alloc] initWithIdentifier:@"tcpip"];
    [tcpipTab setLabel:@"TCP/IP"];
    [advancedTabView addTabViewItem:tcpipTab];
    [tcpipTab release];
    
    // DNS tab
    NSTabViewItem *dnsTab = [[NSTabViewItem alloc] initWithIdentifier:@"dns"];
    [dnsTab setLabel:@"DNS"];
    [advancedTabView addTabViewItem:dnsTab];
    [dnsTab release];
    
    // Proxies tab
    NSTabViewItem *proxiesTab = [[NSTabViewItem alloc] initWithIdentifier:@"proxies"];
    [proxiesTab setLabel:@"Proxies"];
    [advancedTabView addTabViewItem:proxiesTab];
    [proxiesTab release];
    
    // 802.1X tab
    NSTabViewItem *dot1xTab = [[NSTabViewItem alloc] initWithIdentifier:@"8021x"];
    [dot1xTab setLabel:@"802.1X"];
    [advancedTabView addTabViewItem:dot1xTab];
    [dot1xTab release];
    
    [content addSubview:advancedTabView];
    
    // OK button
    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(455, 10, 80, 28)];
    [okButton setBezelStyle:NSRoundedBezelStyle];
    [okButton setTitle:@"OK"];
    [okButton setTarget:self];
    [okButton setAction:@selector(closeAdvanced:)];
    [okButton setKeyEquivalent:@"\r"];
    [content addSubview:okButton];
    [okButton release];
    
    // Cancel button  
    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(365, 10, 80, 28)];
    [cancelButton setBezelStyle:NSRoundedBezelStyle];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(closeAdvanced:)];
    [cancelButton setKeyEquivalent:@"\033"];
    [content addSubview:cancelButton];
    [cancelButton release];
}

#pragma mark - Refresh and Data

- (void)refreshInterfaces:(NSTimer *)timer
{
    @try {
        NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: starting...");
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: backend is nil");
            return;
        }
        
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: backend not available");
            return;
        }
        
        NSArray *newInterfaces = [backend availableInterfaces];
        if (!newInterfaces) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: newInterfaces is nil");
            newInterfaces = [NSArray array];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: got %lu interfaces", (unsigned long)[newInterfaces count]);
        
        if (!interfaces) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: ERROR - interfaces array is nil!");
            return;
        }
        
        // Try to preserve the selected interface by name
        NSString *selectedName = selectedInterface ? [selectedInterface name] : nil;
        
        [interfaces removeAllObjects];
        [interfaces addObjectsFromArray:newInterfaces];
        
        // Try to find the same interface in the new list by name
        if (selectedName) {
            NetworkInterface *foundInterface = nil;
            for (NetworkInterface *iface in interfaces) {
                if ([[iface name] isEqualToString:selectedName]) {
                    foundInterface = iface;
                    break;
                }
            }
            
            if (foundInterface) {
                selectedInterface = foundInterface;
                NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: preserved selection of '%@'", selectedName);
            } else {
                NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: selected interface '%@' no longer available", selectedName);
                selectedInterface = nil;
            }
        }
        
        // If no selection, select first interface
        if (!selectedInterface && [interfaces count] > 0) {
            selectedInterface = [interfaces objectAtIndex:0];
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: auto-selected first interface '%@'", [selectedInterface name]);
        }
        
        if (!serviceTable) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: serviceTable is nil");
            return;
        }
        
        [serviceTable reloadData];
        
        // Ensure table selection matches selectedInterface
        if (selectedInterface) {
            NSInteger index = [interfaces indexOfObject:selectedInterface];
            if (index != NSNotFound) {
                [serviceTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
                NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: synchronized table selection to row %ld", (long)index);
            }
        }
        
        [self updateDetailView];
        [self updateStatusDisplay];
        
        NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)refreshWLANNetworks
{
    if (!backend || ![backend isAvailable]) {
        return;
    }
    
    [scanProgress startAnimation:nil];
    
    // Perform scan in background using NSThread
    [self performSelectorInBackground:@selector(doWLANScanInBackground) withObject:nil];
}

- (void)startWLANRefreshTimer
{
    [self stopWLANRefreshTimer];
    
    // Refresh WLAN networks every 10 seconds
    wlanRefreshTimer = [[NSTimer scheduledTimerWithTimeInterval:10.0
                                                         target:self
                                                       selector:@selector(wlanRefreshTimerFired:)
                                                       userInfo:nil
                                                        repeats:YES] retain];
}

- (void)stopWLANRefreshTimer
{
    if (wlanRefreshTimer) {
        [wlanRefreshTimer invalidate];
        [wlanRefreshTimer release];
        wlanRefreshTimer = nil;
    }
}

- (void)wlanRefreshTimerFired:(NSTimer *)timer
{
    @try {
        if (selectedInterface && [selectedInterface type] == NetworkInterfaceTypeWLAN) {
            [self refreshWLANNetworks];
            [self updateClonedMacPopup];
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] wlanRefreshTimerFired: EXCEPTION: %@ - %@",
                    [exception name], [exception reason]);
    }
}

- (void)doWLANScanInBackground
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSArray *networks = [backend scanForWLANs];
    
    // Update UI on main thread
    [self performSelectorOnMainThread:@selector(wlanScanCompleted:) 
                           withObject:networks 
                        waitUntilDone:NO];
    
    [pool release];
}

- (void)wlanScanCompleted:(NSArray *)networks
{
    @try {
        if (!wlanNetworks) {
            NSDebugLLog(@"gwcomp", @"[Network] wlanScanCompleted: wlanNetworks is nil!");
            return;
        }
        
        [wlanNetworks removeAllObjects];
        if (networks && [networks count] > 0) {
            [wlanNetworks addObjectsFromArray:networks];
            NSDebugLLog(@"gwcomp", @"[Network] wlanScanCompleted: added %lu networks", (unsigned long)[networks count]);
        }
        
        if (wlanTable) {
            [wlanTable reloadData];
        }
        
        if (scanProgress) {
            [scanProgress stopAnimation:nil];
        }

        [self updateClonedMacPopup];
        
        NSDebugLLog(@"gwcomp", @"[Network] wlanScanCompleted: done");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] wlanScanCompleted: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)updateStatusDisplay
{
    @try {
        if (!selectedInterface) {
            if (statusLabel) [statusLabel setStringValue:@"No Network Services"];
            if (statusDetailLabel) [statusDetailLabel setStringValue:@""];
            if (statusIcon) [statusIcon setImage:nil];
            return;
        }
        
        if (![interfaces containsObject:selectedInterface]) {
            if (statusLabel) [statusLabel setStringValue:@"No Network Services"];
            if (statusDetailLabel) [statusDetailLabel setStringValue:@""];
            if (statusIcon) [statusIcon setImage:nil];
            return;
        }
        
        // Set status icon
        NSImage *icon = [self statusIconForInterface:selectedInterface];
        if (statusIcon && icon) {
            [statusIcon setImage:icon];
        }
        
        // Set status text
        NSString *stateStr = [selectedInterface stateString];
        if (statusLabel && stateStr) {
            [statusLabel setStringValue:[NSString stringWithFormat:@"%@: %@", 
                                         [selectedInterface displayName], stateStr]];
        }
        
        // Set detail text
        NSString *detail = [self descriptionForInterface:selectedInterface];
        if (statusDetailLabel && detail) {
            [statusDetailLabel setStringValue:detail];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] updateStatusDisplay: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)updateEnableDisableButtons
{
    @try {
        if (!selectedInterface) {
            [enableButton setEnabled:NO];
            [disableButton setEnabled:NO];
            return;
        }
        
        BOOL isEnabled = [selectedInterface isEnabled];
        BOOL isActive = [selectedInterface isActive];
        
        // Enable button is available when interface is disabled
        [enableButton setEnabled:!isEnabled];
        
        // Disable button is available when interface is enabled
        [disableButton setEnabled:isEnabled || isActive];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] updateEnableDisableButtons: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)updateDetailView
{
    @try {
        if (!selectedInterface) {
            NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: no interface selected");
            if (detailTabView) {
                [detailTabView selectTabViewItemWithIdentifier:@"tcpip"];
            }
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: updating for interface '%@' (type=%d)", 
              [selectedInterface name], (int)[selectedInterface type]);
        
        if (![interfaces containsObject:selectedInterface]) {
            NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: WARNING - selected interface not in list, trying to find by name");
            // Try to find by name
            NSString *name = [selectedInterface name];
            BOOL found = NO;
            for (NetworkInterface *iface in interfaces) {
                if ([[iface name] isEqualToString:name]) {
                    selectedInterface = iface;
                    found = YES;
                    NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: found matching interface by name");
                    break;
                }
            }
            
            if (!found) {
                NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: interface really not in list, clearing");
                selectedInterface = nil;
                if (detailTabView) {
                    [detailTabView selectTabViewItemWithIdentifier:@"tcpip"];
                }
                return;
            }
        }
        
        // Update TCP/IP fields
        IPConfiguration *ipv4 = [selectedInterface ipv4Config];
        if (ipv4) {
            NSString *addr = [ipv4 address];
            if (ipAddressField && addr) [ipAddressField setStringValue:addr];
            
            NSString *mask = [ipv4 subnetMask];
            if (subnetMaskField && mask) [subnetMaskField setStringValue:mask];
            
            NSString *gw = [ipv4 router];
            if (routerField && gw) [routerField setStringValue:gw];
            
            NSArray *dns = [ipv4 dnsServers];
            if (dnsServersField) {
                if (dns && [dns count] > 0) {
                    [dnsServersField setStringValue:[dns componentsJoinedByString:@", "]];
                } else {
                    [dnsServersField setStringValue:@""];
                }
            }
            
            NSArray *search = [ipv4 searchDomains];
            if (searchDomainsField) {
                if (search && [search count] > 0) {
                    [searchDomainsField setStringValue:[search componentsJoinedByString:@", "]];
                } else {
                    [searchDomainsField setStringValue:@""];
                }
            }
            
            // Set configure popup
            if (configureIPv4Popup) {
                switch ([ipv4 method]) {
                    case IPConfigMethodDHCP:
                        [configureIPv4Popup selectItemAtIndex:0];
                        break;
                    case IPConfigMethodManual:
                        [configureIPv4Popup selectItemAtIndex:1];
                        break;
                    case IPConfigMethodDisabled:
                        [configureIPv4Popup selectItemAtIndex:2];
                        break;
                    default:
                        [configureIPv4Popup selectItemAtIndex:0];
                        break;
                }
            }
        }
        
        // Update IPv6 fields
        IPConfiguration *ipv6 = [selectedInterface ipv6Config];
        if (ipv6) {
            NSString *addr6 = [ipv6 address];
            if (ipv6AddressField) {
                [ipv6AddressField setStringValue:addr6 ? addr6 : @""];
            }
            
            // Set configure popup for IPv6
            if (configureIPv6Popup) {
                switch ([ipv6 method]) {
                    case IPConfigMethodDHCP:  // Automatically
                        [configureIPv6Popup selectItemAtIndex:0];
                        break;
                    case IPConfigMethodManual:
                        [configureIPv6Popup selectItemAtIndex:1];
                        break;
                    case IPConfigMethodLinkLocal:
                        [configureIPv6Popup selectItemAtIndex:2];
                        break;
                    case IPConfigMethodDisabled:
                        [configureIPv6Popup selectItemAtIndex:3];
                        break;
                    default:
                        [configureIPv6Popup selectItemAtIndex:0];
                        break;
                }
            }
        } else {
            // No IPv6 config, clear fields
            if (ipv6AddressField) [ipv6AddressField setStringValue:@""];
            if (configureIPv6Popup) [configureIPv6Popup selectItemAtIndex:0];
        }
        
        // Show/hide WLAN tab based on interface type
        if ([selectedInterface type] == NetworkInterfaceTypeWLAN) {
            // Ensure WLAN tab is present for wireless interfaces
            NSInteger wlanTabIndex = [detailTabView indexOfTabViewItemWithIdentifier:@"wlan"];
            if (wlanTabIndex == NSNotFound) {
                // WLAN tab doesn't exist, create and add it
                NSTabViewItem *wlanTab = [[NSTabViewItem alloc] initWithIdentifier:@"wlan"];
                [wlanTab setLabel:@"WLAN"];
                [self createWLANViewForTab:wlanTab];
                [detailTabView addTabViewItem:wlanTab];
                [wlanTab release];
            }
            
            if (detailTabView) {
                [detailTabView selectTabViewItemWithIdentifier:@"wlan"];
            }
            
            if (backend) {
                BOOL wlanOn = [backend isWLANEnabled];
                if (wlanPowerButton) {
                    [wlanPowerButton setTitle:wlanOn ? @"Turn WLAN Off" : @"Turn WLAN On"];
                }
                
                // Start auto-refresh and do initial refresh
                if (wlanOn) {
                    [self startWLANRefreshTimer];
                }
                [self refreshWLANNetworks];
            }
        } else {
            // Remove WLAN tab for non-wireless interfaces
            NSInteger wlanTabIndex = [detailTabView indexOfTabViewItemWithIdentifier:@"wlan"];
            if (wlanTabIndex != NSNotFound) {
                NSTabViewItem *wlanTab = [detailTabView tabViewItemAtIndex:wlanTabIndex];
                [detailTabView removeTabViewItem:wlanTab];
            }
            
            // Stop auto-refresh when not viewing WLAN
            [self stopWLANRefreshTimer];
            
            // Select TCP/IP tab for non-WLAN interfaces
            if (detailTabView) {
                [detailTabView selectTabViewItemWithIdentifier:@"tcpip"];
            }
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)selectInterface:(NetworkInterface *)interface
{
    selectedInterface = interface;
    
    // Update table selection
    NSInteger index = [interfaces indexOfObject:interface];
    if (index != NSNotFound) {
        [serviceTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    }
    
    [self updateDetailView];
    [self updateStatusDisplay];
}

#pragma mark - Actions

- (IBAction)enableInterface:(id)sender
{
    @try {
        if (![self validateSelectedInterface]) {
            [self showWarningAlert:@"No Service Selected" 
                   informativeText:@"Please select a network interface to enable."];
            return;
        }
        
        if (!backend || ![backend isAvailable]) {
            [self showErrorAlert:@"Cannot Enable Interface" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        NSString *displayName = [selectedInterface displayName];
        if (!displayName) {
            displayName = [selectedInterface name];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] Enabling interface: %@", displayName);
        
        BOOL success = [backend enableInterface:selectedInterface];
        
        if (success) {
            // Schedule a refresh after a short delay
            [NSTimer scheduledTimerWithTimeInterval:1.0
                                             target:self
                                           selector:@selector(refreshInterfaces:)
                                           userInfo:nil
                                            repeats:NO];
        } else {
            [self showErrorAlert:@"Enable Failed" 
                 informativeText:[NSString stringWithFormat:
                     @"Failed to enable interface '%@'. Please check the logs for details.",
                     displayName]];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in enableInterface: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Error Enabling Interface" 
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", [exception reason]]];
    }
}

- (IBAction)disableInterface:(id)sender
{
    @try {
        if (![self validateSelectedInterface]) {
            [self showWarningAlert:@"No Service Selected" 
                   informativeText:@"Please select a network interface to disable."];
            return;
        }
        
        if (!backend || ![backend isAvailable]) {
            [self showErrorAlert:@"Cannot Disable Interface" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        NSString *displayName = [selectedInterface displayName];
        if (!displayName) {
            displayName = [selectedInterface name];
        }
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Disable Network Interface?"];
        [alert setInformativeText:[NSString stringWithFormat:
                                   @"Are you sure you want to disable '%@'?\n\n"
                                   @"This will disconnect any active connections.",
                                   displayName]];
        [alert addButtonWithTitle:@"Disable"];
        [alert addButtonWithTitle:@"Cancel"];
        [alert setAlertStyle:NSWarningAlertStyle];
        
        NSModalResponse response = [alert runModal];
        [alert release];
        
        if (response == NSAlertFirstButtonReturn) {
            NSDebugLLog(@"gwcomp", @"[Network] Disabling interface: %@", displayName);
            
            BOOL success = [backend disableInterface:selectedInterface];
            
            if (success) {
                // Schedule a refresh after a short delay
                [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 target:self
                                               selector:@selector(refreshInterfaces:)
                                               userInfo:nil
                                                repeats:NO];
            } else {
                [self showErrorAlert:@"Disable Failed" 
                     informativeText:[NSString stringWithFormat:
                         @"Failed to disable interface '%@'. Please check the logs for details.",
                         displayName]];
            }
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in disableInterface: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Error Disabling Interface" 
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", [exception reason]]];
    }
}

/* Removed - action button was removed in favor of context menu
- (IBAction)actionMenuClicked:(id)sender
{
    NSMenu *menu = [[NSMenu alloc] init];
    
    [menu addItemWithTitle:@"Set Service Order..." action:nil keyEquivalent:@""];
    [menu addItemWithTitle:@"Make Service Inactive" action:@selector(toggleServiceActive:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Duplicate Service..." action:nil keyEquivalent:@""];
    [menu addItemWithTitle:@"Rename Service..." action:nil keyEquivalent:@""];
    
    for (NSMenuItem *item in [menu itemArray]) {
        [item setTarget:self];
    }
    
    [NSMenu popUpContextMenu:menu withEvent:[NSApp currentEvent] forView:enableButton];
    [menu release];
}
*/

- (IBAction)configureIPv4Changed:(id)sender
{
    NSInteger index = [configureIPv4Popup indexOfSelectedItem];
    BOOL manual = (index == 1);
    
    [ipAddressField setEditable:manual];
    [subnetMaskField setEditable:manual];
    [routerField setEditable:manual];
    
    isEditing = YES;
    [applyButton setEnabled:YES];
}

- (IBAction)configureIPv6Changed:(id)sender
{
    NSInteger index = [configureIPv6Popup indexOfSelectedItem];
    BOOL manual = (index == 1);  // "Manually" option
    
    [ipv6AddressField setEditable:manual];
    
    isEditing = YES;
    [applyButton setEnabled:YES];
    
    // TODO: When applying, use the selected IPv6 mode:
    // 0 = Automatically (SLAAC/DHCPv6)
    // 1 = Manually
    // 2 = Link-local only
    // 3 = Off (disable IPv6)
}

- (IBAction)applyChanges:(id)sender
{
    @try {
        if (![self validateSelectedInterface]) {
            [self showWarningAlert:@"No Service Selected" 
                   informativeText:@"Please select a network service to configure."];
            return;
        }
        
        if (!backend || ![backend isAvailable]) {
            [self showErrorAlert:@"Cannot Apply Changes" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] Applying changes for: %@", [selectedInterface displayName]);
        
        // Create/update connection with new settings
        // This would need to be implemented based on what was changed
        
        isEditing = NO;
        [applyButton setEnabled:NO];
        
        [self refreshInterfaces:nil];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in applyChanges: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Error Applying Changes" 
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", [exception reason]]];
    }
}

- (IBAction)revertChanges:(id)sender
{
    isEditing = NO;
    [applyButton setEnabled:NO];
    [self updateDetailView];
}

- (IBAction)renewDHCPLease:(id)sender
{
    @try {
        if (![self validateSelectedInterface]) {
            [self showWarningAlert:@"No Service Selected" 
                   informativeText:@"Please select a network service to renew the DHCP lease."];
            return;
        }
        
        if (!backend || ![backend isAvailable]) {
            [self showErrorAlert:@"Cannot Renew DHCP Lease" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        NSString *interfaceName = [selectedInterface identifier];
        NSDebugLLog(@"gwcomp", @"[Network] Renewing DHCP lease for: %@ (%@)", [selectedInterface name], interfaceName);
        
        // Try using the network helper for DHCP renewal (more reliable than NetworkManager for some systems)
        if ([backend respondsToSelector:@selector(runPrivilegedHelper:error:)]) {
            NSError *error = nil;
            NSArray *args = @[@"dhcp-renew", interfaceName];
            BOOL success = [(NMBackend *)backend runPrivilegedHelper:args error:&error];
            
            if (success) {
                NSDebugLLog(@"gwcomp", @"[Network] DHCP renewal initiated successfully");
                [self showInfoAlert:@"DHCP Lease Renewal" 
                    informativeText:@"DHCP lease renewal has been initiated. This may take a few moments."];
                
                // Schedule a refresh after a short delay
                [NSTimer scheduledTimerWithTimeInterval:3.0
                                                 target:self
                                               selector:@selector(refreshInterfaces:)
                                               userInfo:nil
                                                repeats:NO];
                return;
            } else {
                NSDebugLLog(@"gwcomp", @"[Network] DHCP renewal via helper failed: %@", error);
            }
        }
        
        // Fallback: Disconnect and reconnect to renew DHCP via NetworkManager
        NSDebugLLog(@"gwcomp", @"[Network] Falling back to NetworkManager interface restart");
        [backend disableInterface:selectedInterface];
        
        // Schedule reconnection after delay
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(doEnableInterfaceAfterDelay:)
                                       userInfo:nil
                                        repeats:NO];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in renewDHCPLease: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Error Renewing DHCP Lease" 
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", [exception reason]]];
    }
}

- (void)doEnableInterfaceAfterDelay:(NSTimer *)timer
{
    if (selectedInterface) {
        [backend enableInterface:selectedInterface];
        [self refreshInterfaces:nil];
    }
}

#pragma mark - WLAN Actions

- (IBAction)toggleWLANPower:(id)sender
{
    @try {
        if (!backend || ![backend isAvailable]) {
            [self showErrorAlert:@"Cannot Toggle WLAN" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        BOOL currentState = [backend isWLANEnabled];
        BOOL newState = !currentState;
        
        [backend setWLANEnabled:newState];
        [wlanPowerButton setTitle:newState ? @"Turn WLAN Off" : @"Turn WLAN On"];
        
        if (newState) {
            // Start auto-refresh and do initial refresh
            [self startWLANRefreshTimer];
            [self refreshWLANNetworks];
        } else {
            // Stop auto-refresh when WLAN is off
            [self stopWLANRefreshTimer];
            [wlanNetworks removeAllObjects];
            [wlanTable reloadData];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in toggleWLANPower: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Error Toggling WLAN" 
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", [exception reason]]];
    }
}

- (IBAction)joinNetwork:(id)sender
{
    @try {
        if (!wlanNetworks) {
            [self joinOtherNetwork:sender];
            return;
        }
        
        NSInteger row = [wlanTable selectedRow];
        if (row < 0 || row >= (NSInteger)[wlanNetworks count]) {
            [self joinOtherNetwork:sender];
            return;
        }
        
        WLAN *network = [wlanNetworks objectAtIndex:row];
        if (!network) {
            [self showErrorAlert:@"Error" informativeText:@"Could not get selected network."];
            return;
        }
        [self connectToNetwork:network];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in joinNetwork: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Error Joining Network" 
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", [exception reason]]];
    }
}

- (void)wlanTableDoubleClicked:(id)sender
{
    @try {
        if (!wlanNetworks) {
            return;
        }
        
        NSInteger row = [wlanTable clickedRow];
        if (row < 0 || row >= (NSInteger)[wlanNetworks count]) {
            return;
        }
        
        WLAN *network = [wlanNetworks objectAtIndex:row];
        if (network) {
            [self connectToNetwork:network];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in wlanTableDoubleClicked: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)connectToNetwork:(WLAN *)network
{
    NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: called");
    
    @try {
        if (!network) {
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: network is nil");
            [self showErrorAlert:@"Error" informativeText:@"No network specified."];
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: network SSID = '%@', security = %d, isConnected = %@",
              [network ssid], (int)[network security], [network isConnected] ? @"YES" : @"NO");
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: backend is nil");
            [self showErrorAlert:@"Cannot Connect" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: backend not available");
            [self showErrorAlert:@"Cannot Connect" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        if ([network isConnected]) {
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: already connected, returning");
            return; // Already connected
        }
        
        if ([network security] == WLANSecurityNone) {
            // Open network, connect directly
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: open network, connecting directly");
            [backend connectToWLAN:network withPassword:nil];
            [self refreshWLANNetworks];
        } else {
            // Secured network, show password dialog
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: secured network, showing password dialog");
            [self showPasswordPanelForNetwork:network];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: done");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: EXCEPTION: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Error Connecting to Network" 
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", [exception reason]]];
    }
}

- (IBAction)joinOtherNetwork:(id)sender
{
    @try {
        if (!joinNetworkPanel) {
            [self createJoinNetworkPanel];
        }
        
        // Reset fields
        [joinNetworkSSIDField setStringValue:@""];
        [joinNetworkSecurityPopup selectItemAtIndex:0];
        
        // Show panel as sheet
        [NSApp beginSheet:joinNetworkPanel
           modalForWindow:[[mainView window] isKindOfClass:[NSWindow class]] ? [mainView window] : nil
            modalDelegate:nil
           didEndSelector:nil
              contextInfo:nil];
        
        // Make SSID field first responder
        [joinNetworkPanel makeFirstResponder:joinNetworkSSIDField];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in joinOtherNetwork: %@", [exception reason]);
        [self showErrorAlert:@"Error" informativeText:[exception reason]];
    }
}

- (IBAction)joinOtherNetworkConfirm:(id)sender
{
    @try {
        NSString *ssid = [joinNetworkSSIDField stringValue];
        
        if ([ssid length] == 0) {
            [self showWarningAlert:@"Network Name Required" 
                   informativeText:@"Please enter the network name (SSID)."];
            return;
        }
        
        // Close the panel
        [NSApp endSheet:joinNetworkPanel];
        [joinNetworkPanel orderOut:nil];
        
        // Create a temporary network object
        WLAN *network = [[WLAN alloc] init];
        [network setSsid:ssid];
        
        NSInteger secIndex = [joinNetworkSecurityPopup indexOfSelectedItem];
        if (secIndex == 0) {
            [network setSecurity:WLANSecurityNone];
            [backend connectToWLAN:network withPassword:nil];
            [self refreshWLANNetworks];
        } else {
            [network setSecurity:WLANSecurityWPA2];
            [self showPasswordPanelForNetwork:network];
        }
        [network release];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in joinOtherNetworkConfirm: %@", [exception reason]);
        [self showErrorAlert:@"Error" informativeText:[exception reason]];
    }
}

- (IBAction)joinOtherNetworkCancel:(id)sender
{
    [NSApp endSheet:joinNetworkPanel];
    [joinNetworkPanel orderOut:nil];
}

- (IBAction)disconnectWLAN:(id)sender
{
    @try {
        NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: called");
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: backend is nil");
            [self showErrorAlert:@"Cannot Disconnect" informativeText:@"Network backend not available."];
            return;
        }
        
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: backend not available");
            [self showErrorAlert:@"Cannot Disconnect" informativeText:@"Network service not available."];
            return;
        }
        
        BOOL success = [backend disconnectFromWLAN];
        NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: backend returned %@", success ? @"YES" : @"NO");
        
        // Schedule refresh after a short delay
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(doRefreshAfterDisconnect:)
                                       userInfo:nil
                                        repeats:NO];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: EXCEPTION: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Error Disconnecting"
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", [exception reason]]];
    }
}

- (void)doRefreshAfterDisconnect:(NSTimer *)timer
{
    NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterDisconnect: refreshing...");
    @try {
        [self refreshWLANNetworks];
        [self refreshInterfaces:nil];
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterDisconnect: complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterDisconnect: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

#pragma mark - MAC Address Cloning

- (void)updateClonedMacPopup
{
    @try {
        if (!clonedMacPopup) return;
        NSString *ssid = nil;
        NSInteger row = [wlanTable selectedRow];
        if (wlanNetworks && row >= 0 && row < (NSInteger)[wlanNetworks count]) {
            ssid = [[wlanNetworks objectAtIndex:row] ssid];
        }
        if (!ssid && selectedWLANNetwork) {
            ssid = [selectedWLANNetwork ssid];
        }
        if (!ssid) {
            ssid = [backend connectedWLANSSID];
        }
        if (!ssid) {
            [clonedMacPopup setEnabled:NO];
            return;
        }
        NSLog(@"[Network] updateClonedMacPopup: looking up cloned MAC for SSID '%@'", ssid);
        NSString *current = [backend clonedMacAddressForSSID:ssid];
        NSLog(@"[Network] updateClonedMacPopup: current value = '%@'", current);
        for (NSMenuItem *item in [[clonedMacPopup menu] itemArray]) {
            if ([[item representedObject] isEqualToString:current]) {
                [clonedMacPopup selectItem:item];
                break;
            }
        }
        [clonedMacPopup setEnabled:YES];
    } @catch (NSException *exception) {
        NSLog(@"[Network] updateClonedMacPopup: EXCEPTION: %@ - %@",
              [exception name], [exception reason]);
        [clonedMacPopup setEnabled:NO];
    }
}

- (IBAction)clonedMacChanged:(id)sender
{
    NSString *value = [[clonedMacPopup selectedItem] representedObject];
    if (!value) return;
    NSString *ssid = nil;
    NSInteger row = [wlanTable selectedRow];
    if (wlanNetworks && row >= 0 && row < (NSInteger)[wlanNetworks count]) {
        ssid = [[wlanNetworks objectAtIndex:row] ssid];
    }
    if (!ssid && selectedWLANNetwork) {
        ssid = [selectedWLANNetwork ssid];
    }
    if (!ssid) {
        ssid = [[backend connectedWLAN] ssid];
    }
    if (!ssid) {
        NSLog(@"[Network] clonedMacChanged: no SSID available, cannot set cloned MAC");
        return;
    }
    NSLog(@"[Network] clonedMacChanged: setting cloned MAC for '%@' to '%@'", ssid, value);
    if ([backend setClonedMacAddress:value forSSID:ssid]) {
        NSLog(@"[Network] clonedMacChanged: successfully set cloned MAC for %@ to %@", ssid, value);
    }
}

- (IBAction)refreshWLAN:(id)sender
{
    [self refreshWLANNetworks];
}

#pragma mark - Password Panel

- (void)showPasswordPanelForNetwork:(WLAN *)network
{
    NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: called");
    
    @try {
        if (!network) {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: network is nil");
            [self showErrorAlert:@"Error" informativeText:@"No network specified."];
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: network SSID = '%@'", [network ssid]);
        
        // Release previous pending network if any
        if (pendingNetwork) {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: releasing previous pendingNetwork");
            [pendingNetwork release];
            pendingNetwork = nil;
        }
        
        // Retain the new pending network
        pendingNetwork = [network retain];
        NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: pendingNetwork retained (retainCount: %lu)", 
              (unsigned long)[pendingNetwork retainCount]);
        
        if (!passwordPanel) {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: ERROR - passwordPanel is nil!");
            [self showErrorAlert:@"Error" informativeText:@"Password dialog not available."];
            [pendingNetwork release];
            pendingNetwork = nil;
            return;
        }
        
        if (!passwordSSIDLabel) {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: ERROR - passwordSSIDLabel is nil!");
        } else {
            NSString *labelText = [NSString stringWithFormat:
                                   @"The network \"%@\" requires a password.", 
                                   [network ssid] ?: @"(unknown)"];
            [passwordSSIDLabel setStringValue:labelText];
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: set label to '%@'", labelText);
        }
        
        if (!passwordField) {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: ERROR - passwordField is nil!");
        } else {
            [passwordField setStringValue:@""];
        }
        
        NSWindow *parentWindow = [mainView window];
        NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: parentWindow = %@", parentWindow);
        
        if (parentWindow) {
            [NSApp beginSheet:passwordPanel
               modalForWindow:parentWindow
                modalDelegate:nil
               didEndSelector:nil
                  contextInfo:nil];
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: sheet displayed");
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: no parent window, showing as regular window");
            [passwordPanel makeKeyAndOrderFront:self];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: EXCEPTION: %@ - %@", 
              [exception name], [exception reason]);
        [self showErrorAlert:@"Error" 
             informativeText:[NSString stringWithFormat:@"Could not show password dialog: %@", 
                             [exception reason]]];
    }
}

- (IBAction)passwordConnect:(id)sender
{
    NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: called");
    
    @try {
        // Close the sheet first
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ending sheet...");
        [NSApp endSheet:passwordPanel];
        [passwordPanel orderOut:self];
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: sheet closed");
        
        if (!pendingNetwork) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ERROR - pendingNetwork is nil!");
            [self showErrorAlert:@"Error" informativeText:@"No network selected."];
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: pendingNetwork SSID = '%@'", [pendingNetwork ssid]);
        
        if (!passwordField) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ERROR - passwordField is nil!");
            [pendingNetwork release];
            pendingNetwork = nil;
            [self showErrorAlert:@"Error" informativeText:@"Password field not available."];
            return;
        }
        
        NSString *password = [passwordField stringValue];
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: password length = %lu", (unsigned long)[password length]);
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ERROR - backend is nil!");
            [pendingNetwork release];
            pendingNetwork = nil;
            [self showErrorAlert:@"Error" informativeText:@"Network backend not available."];
            return;
        }
        
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ERROR - backend not available!");
            [pendingNetwork release];
            pendingNetwork = nil;
            [self showErrorAlert:@"Error" informativeText:@"Network service not available."];
            return;
        }
        
        // Copy the network reference before releasing
        WLAN *networkToConnect = [pendingNetwork retain];
        NSString *ssidToConnect = [[pendingNetwork ssid] copy];
        
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: calling backend connectToWLAN for '%@'", ssidToConnect);
        
        // Release pending network before the potentially blocking call
        [pendingNetwork release];
        pendingNetwork = nil;
        
        // Now connect
        BOOL success = [backend connectToWLAN:networkToConnect withPassword:password];
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: backend returned success = %@", success ? @"YES" : @"NO");
        
        [networkToConnect release];
        [ssidToConnect release];
        
        // Refresh after a delay to show new connection
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: scheduling refresh timer");
        [NSTimer scheduledTimerWithTimeInterval:2.0
                                         target:self
                                       selector:@selector(doRefreshAfterConnect:)
                                       userInfo:nil
                                        repeats:NO];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: EXCEPTION: %@ - %@", [exception name], [exception reason]);
        if (pendingNetwork) {
            [pendingNetwork release];
            pendingNetwork = nil;
        }
        [self showErrorAlert:@"Error Connecting" 
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", 
                             [exception reason]]];
    }
}

- (void)doRefreshAfterConnect:(NSTimer *)timer
{
    NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: refreshing...");
    @try {
        if (!backend || ![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: backend not available");
            return;
        }
        
        // Refresh WiFi networks first
        [self refreshWLANNetworks];
        
        // Then refresh interfaces
        [self refreshInterfaces:nil];
        
        // Force update detail view to ensure correct interface is showing
        if (selectedInterface) {
            NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: forcing detail view update for %@", [selectedInterface name]);
            [self updateDetailView];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: refresh complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: EXCEPTION: %@ - %@", 
              [exception name], [exception reason]);
    }
}

- (IBAction)passwordCancel:(id)sender
{
    NSDebugLLog(@"gwcomp", @"[Network] passwordCancel: called");
    
    @try {
        [NSApp endSheet:passwordPanel];
        [passwordPanel orderOut:self];
        
        if (pendingNetwork) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordCancel: releasing pendingNetwork");
            [pendingNetwork release];
            pendingNetwork = nil;
        }
        NSDebugLLog(@"gwcomp", @"[Network] passwordCancel: done");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] passwordCancel: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

#pragma mark - Advanced

- (IBAction)showAdvanced:(id)sender
{
    [NSApp beginSheet:advancedPanel
       modalForWindow:[mainView window]
        modalDelegate:nil
       didEndSelector:nil
          contextInfo:nil];
}

- (IBAction)closeAdvanced:(id)sender
{
    [NSApp endSheet:advancedPanel];
    [advancedPanel orderOut:self];
}

- (IBAction)toggleServiceActive:(id)sender
{
    @try {
        if (!selectedInterface) {
            NSDebugLLog(@"gwcomp", @"[Network] toggleServiceActive: no interface selected");
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] toggleServiceActive: interface '%@' isActive=%@", 
              [selectedInterface name], [selectedInterface isActive] ? @"YES" : @"NO");
        
        BOOL success = NO;
        if ([selectedInterface isActive]) {
            success = [backend disableInterface:selectedInterface];
        } else {
            success = [backend enableInterface:selectedInterface];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] toggleServiceActive: operation returned %@", success ? @"YES" : @"NO");
        
        // Refresh after a short delay to let NetworkManager update
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(doRefreshAfterToggle:)
                                       userInfo:nil
                                        repeats:NO];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] toggleServiceActive: EXCEPTION: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Error Toggling Interface" 
             informativeText:[NSString stringWithFormat:@"An unexpected error occurred: %@", [exception reason]]];
    }
}

- (void)doRefreshAfterToggle:(NSTimer *)timer
{
    NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: refreshing interfaces...");
    @try {
        if (!self) {
            NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: self is nil!");
            return;
        }
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: backend is nil");
            return;
        }
        
        [self refreshInterfaces:nil];
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: refresh complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

#pragma mark - Helper Methods

- (NSImage *)iconForInterfaceType:(NetworkInterfaceType)type
{
    NSString *iconName;
    
    switch (type) {
        case NetworkInterfaceTypeEthernet:
            iconName = @"network-wired";
            break;
        case NetworkInterfaceTypeWLAN:
            iconName = @"network-wireless";
            break;
        case NetworkInterfaceTypeBluetooth:
            iconName = @"bluetooth";
            break;
        case NetworkInterfaceTypeVPN:
            iconName = @"network-vpn";
            break;
        default:
            iconName = @"network-idle";
            break;
    }
    
    NSImage *icon = [NSImage imageNamed:iconName];
    if (!icon) {
        icon = [NSImage imageNamed:@"NSNetwork"];
    }
    
    return icon;
}

- (NSImage *)statusIconForInterface:(NetworkInterface *)interface
{
    if (!interface) {
        return [NSImage imageNamed:@"NSNetwork"];
    }
    
    NSImage *icon = [self iconForInterfaceType:[interface type]];
    
    // For now just return the base icon
    // Could overlay status indicators in the future
    
    return icon;
}

- (NSString *)descriptionForInterface:(NetworkInterface *)interface
{
    if (!interface) {
        return @"";
    }
    
    NSMutableString *desc = [NSMutableString string];
    
    if ([interface state] == NetworkConnectionStateConnected) {
        IPConfiguration *ipv4 = [interface ipv4Config];
        if (ipv4 && [ipv4 address]) {
            [desc appendFormat:@"IP Address: %@", [ipv4 address]];
        }
        
        if ([interface hardwareAddress]) {
            if ([desc length] > 0) [desc appendString:@"\n"];
            [desc appendFormat:@"Hardware Address: %@", [interface hardwareAddress]];
        }
    } else {
        if ([interface hardwareAddress]) {
            [desc appendFormat:@"Hardware Address: %@", [interface hardwareAddress]];
        }
    }
    
    return desc;
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    @try {
        if (tableView == serviceTable) {
            return interfaces ? [interfaces count] : 0;
        } else if (tableView == wlanTable) {
            return wlanNetworks ? [wlanNetworks count] : 0;
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in numberOfRowsInTableView: %@", [exception reason]);
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    @try {
        if (!tableColumn) return nil;
        NSString *identifier = [tableColumn identifier];
        if (!identifier) return nil;
        
        if (tableView == serviceTable) {
            if (!interfaces || row < 0 || row >= (NSInteger)[interfaces count]) return nil;
            NetworkInterface *iface = [interfaces objectAtIndex:row];
            if (!iface) return nil;
            
            if ([identifier isEqualToString:@"icon"]) {
                return [self iconForInterfaceType:[iface type]];
            } else if ([identifier isEqualToString:@"name"]) {
                return [iface displayName] ?: [iface name] ?: @"Unknown";
            }
        } else if (tableView == wlanTable) {
            if (!wlanNetworks || row < 0 || row >= (NSInteger)[wlanNetworks count]) return nil;
            WLAN *network = [wlanNetworks objectAtIndex:row];
            if (!network) return nil;
            
            if ([identifier isEqualToString:@"signal"]) {
                // Return signal strength as icon or text
                int bars = [network signalBars];
                return [NSString stringWithFormat:@"%@", 
                        bars >= 3 ? @"●●●●" : (bars >= 2 ? @"●●●○" : (bars >= 1 ? @"●●○○" : @"●○○○"))];
            } else if ([identifier isEqualToString:@"ssid"]) {
                return [network ssid] ?: @"Unknown";
            } else if ([identifier isEqualToString:@"security"]) {
                return [network securityString] ?: @"";
            } else if ([identifier isEqualToString:@"status"]) {
                return [network isConnected] ? @"✓" : @"";
            }
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in tableView:objectValueForTableColumn:row: %@", [exception reason]);
    }
    
    return nil;
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    @try {
        NSTableView *tableView = [notification object];
        if (!tableView) return;
        
        if (tableView == serviceTable) {
            NSInteger row = [serviceTable selectedRow];
            if (interfaces && row >= 0 && row < (NSInteger)[interfaces count]) {
                selectedInterface = [interfaces objectAtIndex:row];
                [self updateDetailView];
                [self updateStatusDisplay];
                [self updateEnableDisableButtons];
            } else {
                selectedInterface = nil;
                [self updateEnableDisableButtons];
            }
        } else if (tableView == wlanTable) {
            NSInteger row = [wlanTable selectedRow];
            if (wlanNetworks && row >= 0 && row < (NSInteger)[wlanNetworks count]) {
                selectedWLANNetwork = [wlanNetworks objectAtIndex:row];
            } else {
                selectedWLANNetwork = nil;
            }
            [self updateClonedMacPopup];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in tableViewSelectionDidChange: %@", [exception reason]);
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    return YES;
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == serviceTable) {
        if ([[tableColumn identifier] isEqualToString:@"icon"]) {
            if ([cell isKindOfClass:[NSImageCell class]]) {
                [(NSImageCell *)cell setImageScaling:NSImageScaleProportionallyDown];
            }
        }
    }
}

#pragma mark - NetworkBackendDelegate

- (void)networkBackend:(id<NetworkBackend>)aBackend didUpdateInterfaces:(NSArray *)newInterfaces
{
    // Ensure we're on the main thread
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(handleUpdatedInterfaces:) 
                               withObject:newInterfaces 
                            waitUntilDone:NO];
        return;
    }
    [self handleUpdatedInterfaces:newInterfaces];
}

- (void)handleUpdatedInterfaces:(NSArray *)newInterfaces
{
    @try {
        if (!interfaces) {
            NSDebugLLog(@"gwcomp", @"[Network] handleUpdatedInterfaces: interfaces array is nil!");
            return;
        }
        
        [interfaces removeAllObjects];
        if (newInterfaces && [newInterfaces count] > 0) {
            [interfaces addObjectsFromArray:newInterfaces];
            NSDebugLLog(@"gwcomp", @"[Network] handleUpdatedInterfaces: added %lu interfaces", (unsigned long)[newInterfaces count]);
        }
        
        if (serviceTable) {
            [serviceTable reloadData];
        }
        
        [self updateStatusDisplay];

        // Check for captive portal when WLAN connection changes
        NSString *currentWLANSSID = nil;
        for (NetworkInterface *iface in interfaces) {
            if ([iface type] == NetworkInterfaceTypeWLAN && [iface state] == NetworkConnectionStateConnected) {
                currentWLANSSID = [iface name];
                break;
            }
        }
        if (currentWLANSSID && ![currentWLANSSID isEqualToString:previousWLANSSID]) {
            [previousWLANSSID release];
            previousWLANSSID = [currentWLANSSID retain];
            [[self retain] autorelease];
            [CaptivePortalDetector checkForCaptivePortalWithCompletion:^(BOOL isCaptive, NSString *redirectURL) {
                if (isCaptive && redirectURL) {
                    [self captivePortalDetected:redirectURL];
                }
            }];
        } else if (!currentWLANSSID) {
            [previousWLANSSID release];
            previousWLANSSID = nil;
        }

        [self updateClonedMacPopup];
        
        NSDebugLLog(@"gwcomp", @"[Network] handleUpdatedInterfaces: complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] handleUpdatedInterfaces: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)networkBackend:(id<NetworkBackend>)aBackend didFinishWLANScan:(NSArray *)networks
{
    // Ensure we're on the main thread
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(wlanScanCompleted:) 
                               withObject:networks 
                            waitUntilDone:NO];
        return;
    }
    [self wlanScanCompleted:networks];
}

- (void)networkBackend:(id<NetworkBackend>)aBackend didEncounterError:(NSError *)error
{
    // Ensure we're on the main thread
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(handleNetworkError:) 
                               withObject:error 
                            waitUntilDone:NO];
        return;
    }
    [self handleNetworkError:error];
}

- (void)handleNetworkError:(NSError *)error
{
    @try {
        if (!error) {
            NSDebugLLog(@"gwcomp", @"[Network] handleNetworkError: error is nil");
            return;
        }
        
        NSString *errorDesc = [error localizedDescription];
        if (!errorDesc) {
            errorDesc = @"An unknown error occurred";
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] handleNetworkError: showing alert for: %@", errorDesc);
        
        // Use showErrorAlert which is more defensive
        [self showErrorAlert:@"Network Error" informativeText:errorDesc];
        
        NSDebugLLog(@"gwcomp", @"[Network] handleNetworkError: alert dismissed");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] handleNetworkError: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)networkBackend:(id<NetworkBackend>)aBackend WLANEnabledDidChange:(BOOL)enabled
{
    // Ensure we're on the main thread  
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(handleWlanEnabledChange:) 
                               withObject:[NSNumber numberWithBool:enabled] 
                            waitUntilDone:NO];
        return;
    }
    [self handleWlanEnabledChange:[NSNumber numberWithBool:enabled]];
}

- (void)handleWlanEnabledChange:(NSNumber *)enabledNum
{
    BOOL enabled = [enabledNum boolValue];
    [wlanPowerButton setTitle:enabled ? @"Turn WLAN Off" : @"Turn WLAN On"];
    
    if (!enabled) {
        [wlanNetworks removeAllObjects];
        [wlanTable reloadData];
    }
}

#pragma mark - Menu Validation

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    if (menu == serviceContextMenu) {
        // Update menu items based on selected interface state
        for (NSMenuItem *item in [menu itemArray]) {
            SEL action = [item action];
            if (action == @selector(enableInterface:)) {
                if (selectedInterface) {
                    BOOL isEnabled = [selectedInterface isEnabled];
                    [item setEnabled:!isEnabled];
                } else {
                    [item setEnabled:NO];
                }
            } else if (action == @selector(disableInterface:)) {
                if (selectedInterface) {
                    BOOL isEnabled = [selectedInterface isEnabled];
                    BOOL isActive = [selectedInterface isActive];
                    [item setEnabled:isEnabled || isActive];
                } else {
                    [item setEnabled:NO];
                }
            }
        }
    }
}

#pragma mark - Error Handling Helpers

- (void)showErrorAlert:(NSString *)message informativeText:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message ? message : @"Error"];
    [alert setInformativeText:info ? info : @"An unknown error occurred."];
    [alert setAlertStyle:NSCriticalAlertStyle];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];
}

- (void)showWarningAlert:(NSString *)message informativeText:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message ? message : @"Warning"];
    [alert setInformativeText:info ? info : @""];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];
}

- (void)showInfoAlert:(NSString *)message informativeText:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message ? message : @"Information"];
    [alert setInformativeText:info ? info : @""];
    [alert setAlertStyle:NSInformationalAlertStyle];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];
}

- (BOOL)validateSelectedInterface
{
    if (!selectedInterface) {
        return NO;
    }
    
    // Check if the selected interface is still in our interfaces array
    if (![interfaces containsObject:selectedInterface]) {
        selectedInterface = nil;
        return NO;
    }
    
    return YES;
}

#pragma mark - Captive Portal Detection

- (void)captivePortalDetected:(NSString *)redirectURL
{
    if (!redirectURL || [redirectURL length] == 0) {
        return;
    }

    NSDebugLLog(@"gwcomp", @"[Network] Captive portal detected, redirect to: %@", redirectURL);

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Captive Portal Detected"];
    [alert setInformativeText:[NSString stringWithFormat:
        @"The WLAN network requires you to sign in before accessing the internet.\n\n"
        @"Would you like to open the login page in your browser?"]];
    [alert setAlertStyle:NSInformationalAlertStyle];
    [alert addButtonWithTitle:@"Open in Browser"];
    [alert addButtonWithTitle:@"Cancel"];

    NSInteger result = [alert runModal];
    [alert release];

    if (result == NSAlertFirstButtonReturn) {
        NSURL *url = [NSURL URLWithString:redirectURL];
        if (url) {
            [[NSWorkspace sharedWorkspace] openURL:url];
        }
    }
}

@end
