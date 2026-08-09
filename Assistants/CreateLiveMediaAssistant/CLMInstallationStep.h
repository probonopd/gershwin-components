/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import "CLMStreamOperation.h"

@class CLMController;

@interface CLMInstallationStep : NSObject <GSAssistantStepProtocol, CLMStreamOperationDelegate>
{
    NSView *_stepView;
    __weak CLMController *_controller;
    NSProgressIndicator *_progressBar;
    NSTextField *_statusLabel;
    NSTextField *_progressLabel;
    NSTextField *_etaLabel;
    NSTextField *_infoLabel;
    BOOL _installationInProgress;
    BOOL _installationCompleted;
    BOOL _installationSuccessful;
    CLMStreamOperation *_streamOp;
    NSOperationQueue *_opQueue;
    NSTimeInterval _downloadStartTime;
    NSTimeInterval _lastUIUpdateTime;
}

@property (nonatomic, weak) CLMController *controller;

@end
