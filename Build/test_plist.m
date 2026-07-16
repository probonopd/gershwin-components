#import <Foundation/Foundation.h>
int main() {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:@"/Developer/Library/Sources/gershwin-components/Build/Resources/Catalog/MrtonikClock.plist"];
    if (dict) {
        NSLog(@"Dict: %@", dict);
        NSLog(@"Name: %@", [dict objectForKey:@"Name"]);
    } else {
        NSLog(@"Failed to load dict");
    }
    return 0;
}
