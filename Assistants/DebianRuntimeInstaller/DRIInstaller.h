//
// DRIInstaller.h
// Debian Runtime Installer - System Installation
//
// Handles the actual installation of the Debian runtime
//

#import <Foundation/Foundation.h>

@protocol DRIInstallerDelegate <NSObject>
- (void)installer:(id)installer didStartInstallationWithMessage:(NSString *)message;
- (void)installer:(id)installer didUpdateProgress:(NSString *)message;
- (void)installer:(id)installer didCompleteSuccessfully:(BOOL)success withMessage:(NSString *)message;
@end

@interface DRIInstaller : NSObject
@property (nonatomic, assign) id<DRIInstallerDelegate> delegate;
@property (nonatomic, readonly) BOOL isInstalling;

- (void)installRuntimeFromImagePath:(NSString *)imagePath;
- (void)cancelInstallation;
@end
