//
// GSSelectionStep.h
// GSAssistantFramework - Selection Step Base Class
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "GSAssistantFramework.h"

NS_ASSUME_NONNULL_BEGIN

@interface GSSelectionStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSTableView *_tableView;
    NSArrayController *_arrayController;
    NSMutableArray *_items;
    NSString *_stepTitle;
    NSString *_stepDescription;
    id _selectedItem;
    BOOL _allowsEmptySelection;
    BOOL _allowsMultipleSelection;
}

@property (nonatomic, retain) NSString *stepTitle;
@property (nonatomic, retain) NSString *stepDescription;
@property (nonatomic, readonly) NSTableView *tableView;
@property (nonatomic, readonly) NSArrayController *arrayController;
@property (nonatomic, readonly) NSMutableArray *items;
@property (nonatomic, retain) id selectedItem;
@property (nonatomic, assign) BOOL allowsEmptySelection;
@property (nonatomic, assign) BOOL allowsMultipleSelection;

// Subclasses should override these methods
- (void)setupTableColumns;
- (void)setupAdditionalViews:(NSView *)containerView;
- (void)selectionDidChange;
- (void)loadItems;

// Utility methods
- (void)addTableColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width keyPath:(NSString *)keyPath;
- (void)refreshItems;
- (void)selectItemAtIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
