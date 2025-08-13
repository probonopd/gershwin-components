//
// BhyveController.h
// Bhyve Assistant - Main Controller
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import "VNCWindow.h"

@interface BhyveController : NSObject <GSAssistantWindowDelegate>
{
    GSAssistantWindow *_assistantWindow;
    NSString *_selectedISOPath;
    NSString *_selectedISOName;
    long long _selectedISOSize;
    NSString *_vmName;
    NSInteger _allocatedRAM; // In MB
    NSInteger _allocatedCPUs;
    NSInteger _diskSize; // In GB
    BOOL _enableVNC;
    NSInteger _vncPort;
    NSString *_networkMode;
    BOOL _vmRunning;
    NSTask *_bhyveTask;
    VNCWindow *_vncWindow;
    NSString *_bootMode;
    
    // Log viewing
    NSWindow *_logWindow;
    NSTextView *_logTextView;
    NSFileHandle *_logFileHandle;
    NSMutableString *_vmLogBuffer;
}

@property (nonatomic, retain) NSString *selectedISOPath;
@property (nonatomic, retain) NSString *selectedISOName;
@property (nonatomic, assign) long long selectedISOSize;
@property (nonatomic, retain) NSString *vmName;
@property (nonatomic, assign) NSInteger allocatedRAM;
@property (nonatomic, assign) NSInteger allocatedCPUs;
@property (nonatomic, assign) NSInteger diskSize;
@property (nonatomic, assign) BOOL enableVNC;
@property (nonatomic, assign) NSInteger vncPort;
@property (nonatomic, retain) NSString *networkMode;
@property (nonatomic, retain) NSString *bootMode;
@property (nonatomic, assign) BOOL vmRunning;

- (void)showAssistant;

// VM Management
- (void)startVirtualMachine;
- (void)stopVirtualMachine;
- (void)startVNCViewer;
- (void)showVNCConnectionInfo;
- (void)showVMStatus:(NSString *)message;
- (void)showVMError:(NSString *)message;

// Helper methods
- (NSString *)checkSystemRequirements;
- (void)showSystemRequirementsError:(NSString *)message;
- (BOOL)checkBhyveAvailable;
- (BOOL)testBhyveBasicFunction;
- (BOOL)checkLibVNCClientAvailable;
- (BOOL)validateVMConfiguration;
- (NSString *)generateVMCommand;
- (NSString *)generateVNCFramebufferConfig;
- (BOOL)createVirtualDisk;

// Log viewing
- (void)showVMLog;
- (void)updateVMLog:(NSString *)logText;
- (void)updateLogTextView:(NSString *)logText;
- (void)closeLogWindow;
- (void)monitorVMOutput:(NSArray *)pipes;

// Cleanup
- (void)cleanupTemporaryFiles;

@end
