#import <Foundation/Foundation.h>

int main() {
    NSNumber *num1 = [NSNumber numberWithUnsignedInt:1];
    NSNumber *num2 = @((uint32_t)1);
    NSNumber *num3 = @(1U);
    
    printf("numberWithUnsignedInt objCType: %s\n", [num1 objCType]);
    printf("@((uint32_t)1) objCType: %s\n", [num2 objCType]);
    printf("@(1U) objCType: %s\n", [num3 objCType]);
    printf("@encode(uint32_t): %s\n", @encode(uint32_t));
    printf("@encode(unsigned int): %s\n", @encode(unsigned int));
    printf("@encode(int): %s\n", @encode(int));
    printf("@encode(int32_t): %s\n", @encode(int32_t));
    
    // Test the comparison
    const char *objCType = [num1 objCType];
    if (strcmp(objCType, @encode(uint32_t)) == 0) {
        printf("num1 matches @encode(uint32_t)\n");
    } else if (strcmp(objCType, @encode(unsigned int)) == 0) {
        printf("num1 matches @encode(unsigned int)\n");
    } else if (strcmp(objCType, @encode(int32_t)) == 0) {
        printf("num1 matches @encode(int32_t)\n");  
    } else if (strcmp(objCType, @encode(int)) == 0) {
        printf("num1 matches @encode(int)\n");
    } else {
        printf("num1 doesn't match any known type\n");
    }
    
    return 0;
}
