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

#import <AppKit/AppKit.h>

@class BootConfiguration;

@interface BootConfigController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
{
    NSView *mainView;
    NSTableView *configTableView;
    NSArrayController *configArrayController;
    NSMutableArray *bootConfigurations;
    NSButton *createButton;
    NSButton *editButton;
    NSButton *deleteButton;
    NSButton *setActiveButton;
}

- (NSView *)createMainView;
- (void)refreshConfigurations:(id)sender;
- (void)createConfiguration:(id)sender;
- (void)editConfiguration:(id)sender;
- (void)deleteConfiguration:(id)sender;
- (void)setActiveConfiguration:(id)sender;
- (void)tableViewSelectionDidChange:(NSNotification *)notification;
- (void)loadFromBootEnvironments;
- (void)parseBectlOutput:(NSString *)output;
- (void)loadFromLoaderConf;
- (void)parseLoaderConf:(NSString *)content;
- (void)showBootEnvironmentDialog:(BootConfiguration *)config isEdit:(BOOL)isEdit;
- (BOOL)createBootEnvironmentWithBectl:(NSString *)beName;
- (BOOL)deleteBootEnvironmentWithBectl:(NSString *)beName;
- (void)handleDialogCancel:(id)sender;
- (void)showSuccessDialog:(NSString *)title message:(NSString *)message;
- (void)showErrorDialog:(NSString *)title message:(NSString *)message;
- (BOOL)checkPrivilegesForAction:(NSString *)action;

@end
