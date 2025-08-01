#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"=== Real MiniBus Introspection Test ===");
        
        // Connect to MiniBus daemon
        MBClient *client = [[MBClient alloc] init];
        if (![client connectToPath:@"/tmp/minibus-socket"]) {
            NSLog(@"ERROR: Failed to connect to MiniBus daemon");
            return 1;
        }
        
        NSLog(@"✓ Connected to MiniBus daemon");
        
        // Test 1: Call Introspect method
        NSLog(@"\n--- Introspection Test ---");
        
        MBMessage *introspectReply = [client callMethod:@"org.freedesktop.DBus"
                                                   path:@"/org/freedesktop/DBus"
                                              interface:@"org.freedesktop.DBus.Introspectable"
                                                 member:@"Introspect"
                                              arguments:@[]
                                                timeout:5.0];
        
        if (introspectReply && introspectReply.type == MBMessageTypeMethodReturn) {
            NSLog(@"✓ Introspect call succeeded");
            
            if ([introspectReply.arguments count] > 0) {
                NSString *xml = [introspectReply.arguments objectAtIndex:0];
                NSLog(@"✓ Introspection XML received (%lu characters)", [xml length]);
                
                // Check for enhanced features
                NSArray *features = @[
                    @"org.freedesktop.DBus.Introspectable",
                    @"org.freedesktop.DBus.Properties",
                    @"StartServiceByName",
                    @"NameOwnerChanged",
                    @"UpdateActivationEnvironment",
                    @"GetConnectionCredentials"
                ];
                
                for (NSString *feature in features) {
                    if ([xml containsString:feature]) {
                        NSLog(@"✓ Found feature: %@", feature);
                    } else {
                        NSLog(@"⚠ Missing feature: %@", feature);
                    }
                }
                
                // Save the XML for inspection
                [xml writeToFile:@"/tmp/minibus-introspection.xml"
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:nil];
                NSLog(@"✓ Saved introspection XML to /tmp/minibus-introspection.xml");
                
            } else {
                NSLog(@"✗ Introspect reply has no arguments");
            }
        } else if (introspectReply && introspectReply.type == MBMessageTypeError) {
            NSLog(@"✗ Introspect call failed with error: %@", introspectReply.errorName);
            if ([introspectReply.arguments count] > 0) {
                NSLog(@"  Error message: %@", [introspectReply.arguments objectAtIndex:0]);
            }
        } else {
            NSLog(@"✗ Introspect call failed - no response or invalid response");
        }
        
        // Test 2: List available services
        NSLog(@"\n--- Service List Test ---");
        
        MBMessage *listNamesReply = [client callMethod:@"org.freedesktop.DBus"
                                                  path:@"/org/freedesktop/DBus"
                                             interface:@"org.freedesktop.DBus"
                                                member:@"ListNames"
                                             arguments:@[]
                                               timeout:5.0];
        
        if (listNamesReply && listNamesReply.type == MBMessageTypeMethodReturn) {
            NSLog(@"✓ ListNames call succeeded");
            
            if ([listNamesReply.arguments count] > 0) {
                NSArray *names = [listNamesReply.arguments objectAtIndex:0];
                NSLog(@"✓ Found %lu active services:", [names count]);
                for (NSString *name in names) {
                    NSLog(@"  - %@", name);
                }
            }
        } else {
            NSLog(@"✗ ListNames call failed");
        }
        
        // Test 3: Test STRUCT message with real daemon
        NSLog(@"\n--- STRUCT Test with Real Daemon ---");
        
        // Test a simple RequestName call (which uses basic types, not structs)
        MBMessage *requestNameReply = [client callMethod:@"org.freedesktop.DBus"
                                                    path:@"/org/freedesktop/DBus"
                                               interface:@"org.freedesktop.DBus"
                                                  member:@"RequestName"
                                               arguments:@[@"test.StructService", @(0)]
                                                 timeout:5.0];
        
        if (requestNameReply && requestNameReply.type == MBMessageTypeMethodReturn) {
            NSLog(@"✓ RequestName call succeeded");
            if ([requestNameReply.arguments count] > 0) {
                NSLog(@"  Result code: %@", [requestNameReply.arguments objectAtIndex:0]);
            }
        } else {
            NSLog(@"✗ RequestName call failed");
        }
        
        [client disconnect];
        
        NSLog(@"\n=== Real MiniBus Introspection Test Complete ===");
        
        return 0;
    }
}
