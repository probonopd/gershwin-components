#import <Foundation/Foundation.h>

@protocol DSPlatform <NSObject>

@required

// Platform identification
- (NSString *)platformName;
- (BOOL)isAvailable;

// Server (promote) operations
- (BOOL)configureNFSExports;
- (BOOL)enableNFSServer;
- (BOOL)startNFSServer;

// Client (join) operations
- (BOOL)enableNFSClient;
- (BOOL)startNFSClient;
- (BOOL)createNetworkMount:(NSString *)server;
- (BOOL)addFstabEntry:(NSString *)server;
- (BOOL)mountNetwork;

// Discovery
- (NSString *)discoverDirectoryServer;

@end

// Get the appropriate platform implementation for the current system
id<DSPlatform> DSPlatformCreate(void);
