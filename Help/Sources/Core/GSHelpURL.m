/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpURL.h"

@implementation GSHelpURL

+ (NSString *)helpScheme
{
    return @"help";
}

#pragma mark Building

/* Components are opaque identifiers; anything that would change the
 * path structure (slash, query, fragment) or is empty must be rejected
 * rather than silently producing a different URL. */
+ (BOOL)isValidComponent:(NSString *)component
{
    if (component == nil || component.length == 0)
      {
        return NO;
      }
    if ([component rangeOfString: @"/"].location != NSNotFound
        || [component rangeOfString: @"?"].location != NSNotFound
        || [component rangeOfString: @"#"].location != NSNotFound)
      {
        return NO;
      }
    return YES;
}

+ (NSString *)escapedComponent:(NSString *)component
{
    NSCharacterSet *allowed =
        [NSCharacterSet alphanumericCharacterSet];
    NSString *escaped = [component
        stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    /* The fallback keeps the builder total for exotic-but-legal input;
     * URLWithString below still rejects anything unrepresentable. */
    return escaped ?: component;
}

+ (NSURL *)urlWithKind:(NSString *)kind
            components:(NSArray<NSString *> *)components
{
    for (NSString *component in components)
      {
        if (![self isValidComponent:component])
          {
            return nil;
          }
      }
    NSMutableArray *parts =
        [NSMutableArray arrayWithObject:[self escapedComponent:kind]];
    for (NSString *component in components)
      {
        [parts addObject:[self escapedComponent:component]];
      }
    return [NSURL URLWithString:
                [NSString stringWithFormat:@"%@://%@",
                                           [GSHelpURL helpScheme],
                                           [parts componentsJoinedByString: @"/"]]];
}

+ (NSURL *)appURLWithApplication:(NSString *)application
                        document:(NSString *)document
{
    return [self urlWithKind: @"app"
                  components: @[ application ?: @"", document ?: @"" ]];
}

+ (NSURL *)manURLWithCommand:(NSString *)command
                     section:(NSString *)section
{
    return [self urlWithKind: @"man"
                  components: @[ command ?: @"", section ?: @"" ]];
}

+ (NSURL *)gsdocURLWithFramework:(NSString *)framework
                          symbol:(NSString *)symbol
{
    return [self urlWithKind: @"gsdoc"
                  components: @[ framework ?: @"", symbol ?: @"" ]];
}

#pragma mark Decomposing

+ (BOOL)isHelpURL:(NSURL *)url
{
    return url != nil
        && [[url scheme] caseInsensitiveCompare:[GSHelpURL helpScheme]]
               == NSOrderedSame;
}

+ (NSString *)kindOfURL:(NSURL *)url
{
    if (![self isHelpURL:url] || [url host].length == 0)
      {
        return nil;
      }
    NSString *kind = [[url host] lowercaseString];
    if ([kind isEqualToString: @"app"] || [kind isEqualToString: @"man"]
        || [kind isEqualToString: @"gsdoc"])
      {
        return kind;
      }
    return nil;
}

+ (NSArray<NSString *> *)componentsOfURL:(NSURL *)url
{
    if (![self isHelpURL:url])
      {
        return nil;
      }
    NSArray<NSString *> *rawComponents = [[url path] pathComponents];
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *component in rawComponents)
      {
        /* pathComponents yields the leading "/" and any trailing one
         * from "help://man/ls/1/"; both carry no information. */
        if ([component isEqualToString: @"/"] || component.length == 0)
          {
            continue;
          }
        NSString *decoded = [component
            stringByRemovingPercentEncoding];
        [result addObject:decoded ?: component];
      }
    return result;
}

+ (NSString *)pairComponentOfURL:(NSURL *)url
                       wantedKind:(NSString *)wantedKind
                            index:(NSUInteger)index
{
    NSString *kind = [self kindOfURL:url];
    /* Cross-kind accessors stay nil: an app URL has no command, a
     * man URL no application, and so on. */
    if (kind == nil || ![kind isEqualToString:wantedKind])
      {
        return nil;
      }
    NSArray<NSString *> *components = [self componentsOfURL:url];
    /* More than two components means the URL is over-specified and
     * therefore malformed; fewer means an incomplete URL whose
     * present components stay readable. */
    if (components == nil || components.count > 2
        || index >= components.count)
      {
        return nil;
      }
    return components[index];
}

+ (NSString *)applicationOfURL:(NSURL *)url
{
    return [self pairComponentOfURL:url wantedKind:@"app" index:0];
}

+ (NSString *)documentOfURL:(NSURL *)url
{
    return [self pairComponentOfURL:url wantedKind:@"app" index:1];
}

+ (NSString *)commandOfURL:(NSURL *)url
{
    return [self pairComponentOfURL:url wantedKind:@"man" index:0];
}

+ (NSString *)sectionOfURL:(NSURL *)url
{
    return [self pairComponentOfURL:url wantedKind:@"man" index:1];
}

+ (NSString *)frameworkOfURL:(NSURL *)url
{
    return [self pairComponentOfURL:url wantedKind:@"gsdoc" index:0];
}

+ (NSString *)symbolOfURL:(NSURL *)url
{
    return [self pairComponentOfURL:url wantedKind:@"gsdoc" index:1];
}

@end
