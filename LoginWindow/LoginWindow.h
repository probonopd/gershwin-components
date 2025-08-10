// Copyright (c) 2025, Simon Peter
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "LoginWindowPAM.h"

@interface LoginWindow : NSObject <NSTextFieldDelegate, NSWindowDelegate>
{
    NSWindow *loginWindow;
    NSTextField *usernameField;
    NSSecureTextField *passwordField;
    NSButton *loginButton;
    NSButton *shutdownButton;
    NSButton *restartButton;
    NSImageView *logoView;
    NSTextField *statusLabel;
    LoginWindowPAM *pamAuth;
    NSPopUpButton *sessionDropdown;
    NSArray *availableSessions;
    NSArray *availableSessionExecs;
    NSString *selectedSessionExec;
    pid_t sessionPid;
    uid_t sessionUid;
    gid_t sessionGid;
    BOOL didStartXServer;
    pid_t xServerPid;
    BOOL isTerminating;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (void)createLoginWindow;
- (void)loginButtonPressed:(id)sender;
- (void)shutdownButtonPressed:(id)sender;
- (void)restartButtonPressed:(id)sender;
- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password;
- (void)startUserSession:(NSString *)username;
- (void)showStatus:(NSString *)message;
- (void)sessionChanged:(id)sender;
- (void)resetLoginWindow;
- (BOOL)trySystemAction:(NSString *)actionType;
- (void)killAllSessionProcesses:(uid_t)uid;
- (BOOL)isXServerRunning;
- (BOOL)startXServer;
- (void)ensureXServerRunning;
- (void)stopXServerIfStartedByUs;
- (void)cleanupExistingXServer;
- (void)shakeWindow;
- (void)saveLastLoggedInUser:(NSString *)username;
- (NSString *)loadLastLoggedInUser;
- (void)updateLoginButtonState;
- (void)clearFieldsAndShake;
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector;

@end
