/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Network Controller
 *
 * Main controller for the Network preference pane UI.
 * Provides a classic interface for managing wired and wireless networks.
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "NetworkBackend.h"

@interface NetworkController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NetworkBackendDelegate>
{
    // Backend
    id<NetworkBackend> backend;
    
    // Main view
    NSView *mainView;
    
    // Service list (left side)
    NSBox *serviceBox;
    NSScrollView *serviceScrollView;
    NSTableView *serviceTable;
    NSButton *enableButton;
    NSButton *disableButton;
    NSMenu *serviceContextMenu;
    
    // Detail view (right side)  
    NSBox *detailBox;
    NSView *detailView;
    NSTabView *detailTabView;
    
    // Status area
    NSImageView *statusIcon;
    NSTextField *statusLabel;
    NSTextField *statusDetailLabel;
    
    // Ethernet tab
    NSView *ethernetView;
    NSPopUpButton *configureIPv4Popup;
    NSPopUpButton *configureIPv6Popup;
    NSTextField *ipAddressField;
    NSTextField *subnetMaskField;
    NSTextField *routerField;
    NSTextField *ipv6AddressField;
    NSTextField *dnsServersField;
    NSTextField *searchDomainsField;
    NSButton *dhcpLeaseButton;
    
    // WiFi tab
    NSView *wlanView;
    NSScrollView *wlanScrollView;
    NSTableView *wlanTable;
    NSButton *wlanPowerButton;
    NSButton *joinNetworkButton;
    NSButton *disconnectButton;
    NSProgressIndicator *scanProgress;
    NSButton *refreshButton;
    NSPopUpButton *preferredNetworksPopup;
    NSPopUpButton *clonedMacPopup;
    NSTextField *clonedMacLabel;
    
    // Advanced sheet
    NSPanel *advancedPanel;
    NSTabView *advancedTabView;
    
    // WLAN password sheet
    NSPanel *passwordPanel;
    NSTextField *passwordSSIDLabel;
    NSSecureTextField *passwordField;
    NSButton *rememberPasswordCheckbox;
    NSButton *passwordCancelButton;
    NSButton *passwordConnectButton;
    WLAN *pendingNetwork;
    
    // Join other network panel
    NSPanel *joinNetworkPanel;
    NSTextField *joinNetworkSSIDField;
    NSPopUpButton *joinNetworkSecurityPopup;
    
    // WLAN refresh timer
    NSTimer *wlanRefreshTimer;
    
    // Data
    NSMutableArray *interfaces;
    NSMutableArray *wlanNetworks;
    NetworkInterface *selectedInterface;
    WLAN *selectedWLANNetwork;
    
    // Refresh timer
    NSTimer *refreshTimer;
    BOOL isEditing;
    
    // Captive portal detection
    NSString *previousWLANSSID;
}

// View creation
- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)createServiceListViewWithFrame:(NSRect)frame;
- (void)createDetailViewWithFrame:(NSRect)frame;
- (void)createStatusAreaWithFrame:(NSRect)frame;
- (void)createTCPIPViewForTab:(NSTabViewItem *)tab;
- (void)createDNSViewForTab:(NSTabViewItem *)tab;
- (void)createWLANViewForTab:(NSTabViewItem *)tab;
- (void)createPasswordPanel;
- (void)createJoinNetworkPanel;
- (void)createAdvancedPanel;
- (void)createUnavailableView;

// Refresh
- (void)refreshInterfaces:(NSTimer *)timer;
- (void)refreshWLANNetworks;
- (void)startWLANRefreshTimer;
- (void)stopWLANRefreshTimer;
- (void)wlanRefreshTimerFired:(NSTimer *)timer;
- (void)doWLANScanInBackground;
- (void)wlanScanCompleted:(NSArray *)networks;
- (void)updateStatusDisplay;
- (void)updateDetailView;
- (void)selectInterface:(NetworkInterface *)interface;

// Actions
- (IBAction)enableInterface:(id)sender;
- (IBAction)disableInterface:(id)sender;
- (IBAction)configureIPv4Changed:(id)sender;
- (IBAction)renewDHCPLease:(id)sender;
- (void)doEnableInterfaceAfterDelay:(NSTimer *)timer;

// WLAN actions
- (IBAction)toggleWLANPower:(id)sender;
- (IBAction)joinNetwork:(id)sender;
- (IBAction)joinOtherNetwork:(id)sender;
- (IBAction)joinOtherNetworkConfirm:(id)sender;
- (IBAction)joinOtherNetworkCancel:(id)sender;
- (IBAction)disconnectWLAN:(id)sender;
- (void)connectToNetwork:(WLAN *)network;
- (void)wlanTableDoubleClicked:(id)sender;

// Password panel
- (IBAction)passwordConnect:(id)sender;
- (IBAction)passwordCancel:(id)sender;
- (void)showPasswordPanelForNetwork:(WLAN *)network;
- (void)doRefreshAfterConnect:(NSTimer *)timer;

// Advanced
- (IBAction)showAdvanced:(id)sender;
- (IBAction)closeAdvanced:(id)sender;
- (IBAction)toggleServiceActive:(id)sender;

// Delegate helpers
- (void)handleUpdatedInterfaces:(NSArray *)newInterfaces;
- (void)handleNetworkError:(NSError *)error;
- (void)handleWlanEnabledChange:(NSNumber *)enabledNum;

// Helpers
- (NSImage *)iconForInterfaceType:(NetworkInterfaceType)type;
- (NSImage *)statusIconForInterface:(NetworkInterface *)interface;
- (NSString *)descriptionForInterface:(NetworkInterface *)interface;
- (void)showErrorAlert:(NSString *)message informativeText:(NSString *)info;
- (void)showWarningAlert:(NSString *)message informativeText:(NSString *)info;
- (BOOL)validateSelectedInterface;

// Captive portal detection
- (void)captivePortalDetected:(NSString *)redirectURL;

@end
