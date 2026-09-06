/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "GSAssistantFramework.h"

@class GammaController;

@interface ColorAssistantDelegate : NSObject <NSApplicationDelegate, GSAssistantWindowDelegate>
{
    NSString *_selectedDisplay;
    double _whitePoint;
    double _gammaValue;
    double _shadows;
    double _midtones;
    double _highlights;
    BOOL _advancedEnabled;
    GammaController *_gammaCtrl;
}
- (NSString *)selectedDisplay;
- (void)updateSelectedDisplay:(NSString *)v;
- (double)whitePoint;
- (void)setWhitePoint:(double)v;
- (double)gammaValue;
- (void)setGammaValue:(double)v;
- (double)shadows;
- (void)setShadows:(double)v;
- (double)midtones;
- (void)setMidtones:(double)v;
- (double)highlights;
- (void)setHighlights:(double)v;
- (BOOL)advancedEnabled;
- (void)setAdvancedEnabled:(BOOL)v;
- (GammaController *)gammaCtrl;
@end
