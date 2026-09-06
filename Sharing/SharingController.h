/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Sharing Controller - Manages UI and service control
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GSServiceDiscoveryManager;

@interface SharingController : NSObject
{
    // Hostname section
    NSTextField *hostnameField;
    NSButton *applyHostnameButton;
    NSTextField *hostnameStatusLabel;
    
    // Service checkboxes
    NSButton *sshCheckbox;
    NSButton *vncCheckbox;
    NSButton *sftpCheckbox;
    NSButton *afpCheckbox;
    NSButton *smbCheckbox;
    NSButton *webCheckbox;
    NSButton *mediaCheckbox;
    NSButton *rdpCheckbox;
    NSButton *cloudCheckbox;

    // Status labels
    NSTextField *sshStatusLabel;
    NSTextField *vncStatusLabel;
    NSTextField *sftpStatusLabel;
    NSTextField *afpStatusLabel;
    NSTextField *smbStatusLabel;
    NSTextField *webStatusLabel;
    NSTextField *mediaStatusLabel;
    NSTextField *rdpStatusLabel;
    NSTextField *cloudStatusLabel;

    // Information displays
    NSTextField *sshInfoLabel;
    NSTextField *vncInfoLabel;
    NSTextField *sftpInfoLabel;
    NSTextField *afpInfoLabel;
    NSTextField *smbInfoLabel;
    NSTextField *webInfoLabel;
    NSTextField *mediaInfoLabel;
    NSTextField *rdpInfoLabel;
    NSTextField *cloudInfoLabel;
    
    // mDNS status label
    NSTextField *mdnsStatusLabel;
    
    // Current status
    BOOL sshEnabled;
    BOOL vncEnabled;
    BOOL sftpEnabled;
    BOOL afpEnabled;
    BOOL smbEnabled;
    BOOL webEnabled;
    BOOL mediaEnabled;
    BOOL rdpEnabled;
    BOOL cloudEnabled;

    // Installation state
    BOOL sshInstalled;
    BOOL vncInstalled;
    BOOL sftpInstalled;
    BOOL afpInstalled;
    BOOL smbInstalled;
    BOOL webInstalled;
    BOOL mediaInstalled;
    BOOL rdpInstalled;
    BOOL cloudInstalled;

    NSString *currentHostname;
    
    // Path to helper
    NSString *helperPath;
    
    // Service discovery manager
    GSServiceDiscoveryManager *serviceDiscoveryManager;

    // Guards against concurrent refreshStatus: calls
    BOOL isRefreshingStatus;
}

- (NSView *)createMainView;
- (void)refreshStatus:(id)sender;
- (void)applyHostname:(id)sender;
- (void)toggleSSH:(id)sender;
- (void)toggleVNC:(id)sender;
- (void)toggleSFTP:(id)sender;
- (void)toggleAFP:(id)sender;
- (void)toggleSMB:(id)sender;
- (void)toggleWeb:(id)sender;
- (void)toggleMedia:(id)sender;
- (void)toggleRDP:(id)sender;
- (void)toggleCloud:(id)sender;
- (void)hostnameDidChange:(NSNotification *)notification;

@end
