//
//  SimpleColor.m
//  libDSStore - Simple color replacement for headless systems
//

#import "SimpleColor.h"

@implementation SimpleColor

+ (SimpleColor *)colorWithRed:(float)red green:(float)green blue:(float)blue alpha:(float)alpha {
    SimpleColor *color = [[SimpleColor alloc] init];
    color->_red = red;
    color->_green = green;
    color->_blue = blue;
    color->_alpha = alpha;
    return [color autorelease];
}

- (void)getRed:(float *)red green:(float *)green blue:(float *)blue alpha:(float *)alpha {
    if (red) *red = _red;
    if (green) *green = _green;
    if (blue) *blue = _blue;
    if (alpha) *alpha = _alpha;
}

@end
