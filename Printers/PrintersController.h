/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// Forward declaration for CUPS types
typedef struct cups_dest_s cups_dest_t;
typedef struct cups_job_s cups_job_t;

// Represents a printer
@interface PrinterInfo : NSObject
{
    NSString *name;
    NSString *displayName;
    NSString *location;
    NSString *makeModel;
    NSString *deviceURI;
    NSString *state;
    BOOL isDefault;
    BOOL isShared;
    BOOL acceptingJobs;
    int jobCount;
}

@property (retain) NSString *name;
@property (retain) NSString *displayName;
@property (retain) NSString *location;
@property (retain) NSString *makeModel;
@property (retain) NSString *deviceURI;
@property (retain) NSString *state;
@property BOOL isDefault;
@property BOOL isShared;
@property BOOL acceptingJobs;
@property int jobCount;

@end

// Represents a print job
@interface PrintJobInfo : NSObject
{
    int jobId;
    NSString *printerName;
    NSString *title;
    NSString *user;
    NSString *state;
    int size;
    NSDate *creationTime;
}

@property int jobId;
@property (retain) NSString *printerName;
@property (retain) NSString *title;
@property (retain) NSString *user;
@property (retain) NSString *state;
@property int size;
@property (retain) NSDate *creationTime;

@end

// Represents a discovered device
@interface DiscoveredDevice : NSObject
{
    NSString *deviceClass;
    NSString *deviceId;
    NSString *deviceInfo;
    NSString *deviceMakeModel;
    NSString *deviceURI;
    NSString *deviceLocation;
}

@property (retain) NSString *deviceClass;
@property (retain) NSString *deviceId;
@property (retain) NSString *deviceInfo;
@property (retain) NSString *deviceMakeModel;
@property (retain) NSString *deviceURI;
@property (retain) NSString *deviceLocation;

@end

@interface PrintersController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
{
    NSView *mainView;
    NSTableView *printerTable;
    NSTableView *jobTable;
    NSScrollView *printerScroll;
    NSScrollView *jobScroll;
    
    NSButton *addButton;
    NSButton *removeButton;
    NSButton *defaultButton;
    NSButton *optionsButton;
    NSButton *cancelJobButton;
    NSButton *pauseJobButton;
    
    NSTextField *statusLabel;
    NSTextField *printerInfoLabel;
    
    NSMutableArray *printers;
    NSMutableArray *jobs;
    NSMutableArray *discoveredDevices;
    
    PrinterInfo *selectedPrinter;
    PrintJobInfo *selectedJob;
    
    NSPanel *addPrinterPanel;
    NSTableView *deviceTable;
    NSScrollView *deviceScroll;
    NSTextField *printerNameField;
    NSTextField *printerLocationField;
    NSPopUpButton *driverPopup;
    NSButton *discoverButton;
    NSProgressIndicator *discoverProgress;
    
    BOOL cupsAvailable;
    BOOL isDiscovering;
    BOOL userInLpadminGroup;
    NSTextField *privilegeWarningLabel;
}

- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)refreshPrinters:(NSTimer *)timer;
- (void)refreshJobs;
- (BOOL)isUserInLpadminGroup;
- (void)showPrivilegeWarningIfNeeded;

// Printer actions
- (IBAction)addPrinter:(id)sender;
- (IBAction)removePrinter:(id)sender;
- (IBAction)setDefaultPrinter:(id)sender;
- (IBAction)showPrinterOptions:(id)sender;
- (IBAction)enablePrinter:(id)sender;
- (IBAction)disablePrinter:(id)sender;

// Job actions
- (IBAction)cancelJob:(id)sender;
- (IBAction)pauseResumeJob:(id)sender;

// Add printer panel
- (IBAction)discoverDevices:(id)sender;
- (IBAction)confirmAddPrinter:(id)sender;
- (IBAction)cancelAddPrinter:(id)sender;

// CUPS operations
- (BOOL)isCupsAvailable;
- (NSArray *)getAvailableDrivers;

@end
