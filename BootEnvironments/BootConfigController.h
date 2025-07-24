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
