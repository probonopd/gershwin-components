//
// BADiskSelectionStep.h
// Backup Assistant - Disk Selection Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@class BAController;

@interface BADiskSelectionStep : GSAssistantStep
{
    BAController *_controller;
    NSTableView *_diskTableView;
    NSArrayController *_diskArrayController;
    NSMutableArray *_availableDisks;
    NSTimer *_refreshTimer;
    NSTextField *_statusLabel;
    NSTextField *_selectedDiskInfo;
    NSMutableDictionary *_diskSpaceCache;  // Cache for disk space calculations
}

@property (nonatomic, assign) BAController *controller;

- (id)initWithController:(BAController *)controller;
- (void)refreshDiskList;
- (void)analyzeDisk:(NSString *)diskDevice;
- (void)performDiskAnalysis:(NSString *)diskDevice;
- (void)updateAnalysisResult:(NSDictionary *)resultInfo;
- (void)calculateDiskSpaceAsync:(NSString *)diskDevice;
- (void)updateDiskSpaceCache:(NSDictionary *)info;

@end
