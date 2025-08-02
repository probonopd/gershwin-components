#import <Foundation/Foundation.h>

int main() {
    NSNumber *num1 = [NSNumber numberWithUnsignedInt:1];
    NSNumber *num2 = @((uint32_t)1);
    NSNumber *num3 = @(1U);
    
    printf("numberWithUnsignedInt: %s\n", [num1 objCType]);
    printf("@((uint32_t)1): %s\n", [num2 objCType]);
    printf("@(1U): %s\n", [num3 objCType]);
    printf("@encode(uint32_t): %s\n", @encode(uint32_t));
    printf("@encode(unsigned int): %s\n", @encode(unsigned int));
    
    return 0;
}
