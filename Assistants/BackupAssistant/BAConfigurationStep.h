//
// BAConfigurationStep.h
// Backup Assistant - Configuration Step
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

@class BAController;

@interface BAConfigurationStep : GSAssistantStep
{
    BAController *_controller;
    NSTextField *_operationLabel;
    NSTextField *_spaceInfoLabel;
    NSButton *_confirmCheckbox;
    NSTableView *_snapshotTableView;
    NSTableView *_itemsTableView;
    NSScrollView *_snapshotScrollView;
    NSScrollView *_itemsScrollView;
    NSMutableArray *_availableSnapshots;
    NSMutableArray *_selectableItems;
    BOOL _spaceCalculationInProgress;
}

@property (nonatomic, assign) BAController *controller;

- (id)initWithController:(BAController *)controller;
- (void)updateConfigurationView;
- (void)calculateSpaceRequirements;
- (void)performSpaceCalculation;
- (void)updateSpaceInfo:(NSDictionary *)spaceInfo;
- (void)performSnapshotLoad;
- (void)updateSnapshots:(NSArray *)snapshots;

@end
