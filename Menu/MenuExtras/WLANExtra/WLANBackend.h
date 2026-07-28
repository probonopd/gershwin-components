/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLANBackend : NSObject

- (BOOL)isAvailable;
- (BOOL)isWLANEnabled;
- (void)setWLANEnabled:(BOOL)enabled;
- (nullable NSString *)connectedSSID;
- (int)signalStrength; // dBm
- (NSArray<NSDictionary *> *)scanNetworks; // @{@"ssid":, @"signal":, @"security":, @"bssid":}
- (BOOL)connectToNetwork:(NSString *)ssid password:(nullable NSString *)password;
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
