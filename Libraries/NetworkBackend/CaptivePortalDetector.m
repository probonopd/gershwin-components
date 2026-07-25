/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CaptivePortalDetector.h"
#include <curl/curl.h>
#include <string.h>

#define CAPTIVE_PORTAL_PROBE_URL "http://example.com"
#define CAPTIVE_PORTAL_PROBE_BASE_URL @"http://example.com"
#define CAPTIVE_PORTAL_MIN_INTERVAL 60.0
// example.com returns this string in the body on success
#define EXPECTED_PROBE_MARKER "Example Domain"

struct CaptivePortalResponse {
    char *location;
    char *body;   // response body for content check
    size_t bodyLen;
};

static size_t captivePortalWriteCallback(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    size_t total = size * nmemb;
    struct CaptivePortalResponse *resp = (struct CaptivePortalResponse *)userdata;
    char *newBody = realloc(resp->body, resp->bodyLen + total + 1);
    if (newBody) {
        memcpy(newBody + resp->bodyLen, ptr, total);
        resp->bodyLen += total;
        newBody[resp->bodyLen] = '\0';
        resp->body = newBody;
    }
    return total;
}

static size_t captivePortalHeaderCallback(char *buffer, size_t size, size_t nitems, void *userdata)
{
    size_t total = size * nitems;
    struct CaptivePortalResponse *resp = (struct CaptivePortalResponse *)userdata;

    const char *prefix = "Location: ";
    size_t prefixLen = strlen(prefix);
    if (total >= prefixLen && strncasecmp(buffer, prefix, prefixLen) == 0) {
        size_t valueLen = total - prefixLen;
        char *loc = malloc(valueLen + 1);
        if (loc) {
            memcpy(loc, buffer + prefixLen, valueLen);
            loc[valueLen] = '\0';
            char *nl = strchr(loc, '\r');
            if (nl) *nl = '\0';
            nl = strchr(loc, '\n');
            if (nl) *nl = '\0';
            if (resp->location) free(resp->location);
            resp->location = loc;
        }
    }
    return total;
}

static volatile int32_t _captivePortalCheckPending = 0;
static NSTimeInterval _lastCaptivePortalCheckTime = 0;

@interface CaptivePortalDetector (Private)
+ (void)_runCheckWithCompletion:(void (^)(BOOL, NSString *))completion;
+ (void)_callCompletionOnMainThread:(NSArray *)args;
@end

@implementation CaptivePortalDetector

+ (void)checkForCaptivePortalWithCompletion:(void (^)(BOOL isCaptive, NSString *redirectURL))completion
{
    if (!completion) return;

    @autoreleasepool {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - _lastCaptivePortalCheckTime < CAPTIVE_PORTAL_MIN_INTERVAL) {
            return;
        }
        _lastCaptivePortalCheckTime = now;

        if (__sync_lock_test_and_set(&_captivePortalCheckPending, 1)) {
            return;
        }

        [self performSelectorInBackground:@selector(_runCheckWithCompletion:)
                               withObject:[completion copy]];
    }
}

+ (void)checkForCaptivePortalForceWithCompletion:(void (^)(BOOL isCaptive, NSString *redirectURL))completion
{
    if (!completion) return;

    @autoreleasepool {
        if (__sync_lock_test_and_set(&_captivePortalCheckPending, 1)) {
            return;
        }

        _lastCaptivePortalCheckTime = [NSDate timeIntervalSinceReferenceDate];

        [self performSelectorInBackground:@selector(_runCheckWithCompletion:)
                               withObject:[completion copy]];
    }
}

+ (void)_runCheckWithCompletion:(void (^)(BOOL, NSString *))completion
{
    @autoreleasepool {
        CURL *curl = curl_easy_init();
        if (!curl) {
            __sync_lock_release(&_captivePortalCheckPending);
            return;
        }

        struct CaptivePortalResponse resp;
        memset(&resp, 0, sizeof(resp));
        resp.body = NULL;
        resp.bodyLen = 0;

        curl_easy_setopt(curl, CURLOPT_URL, CAPTIVE_PORTAL_PROBE_URL);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 10L);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, captivePortalWriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);
        curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, captivePortalHeaderCallback);
        curl_easy_setopt(curl, CURLOPT_HEADERDATA, &resp);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "CaptivePortalDetector/1.0");
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

        CURLcode res = curl_easy_perform(curl);

        BOOL isCaptive = NO;
        NSString *redirectURL = nil;

        char *effectiveURL = NULL;
        curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effectiveURL);

        if (res == CURLE_OK) {
            if (effectiveURL
                && strcasecmp(effectiveURL, CAPTIVE_PORTAL_PROBE_URL) != 0
                && strcasecmp(effectiveURL, CAPTIVE_PORTAL_PROBE_URL "/") != 0) {
                // The portal redirected us — the effective URL is the
                // actual login page.
                redirectURL = [NSString stringWithUTF8String:effectiveURL];
                isCaptive = YES;
            } else {
                // Same probe URL (no redirect). Check body for the
                // expected marker to distinguish internet from portal.
                if (resp.body && strstr(resp.body, EXPECTED_PROBE_MARKER) != NULL) {
                    isCaptive = NO;
                } else {
                    isCaptive = YES;
                }
            }
        } else if (res == CURLE_GOT_NOTHING
                   || res == CURLE_COULDNT_RESOLVE_HOST
                   || res == CURLE_COULDNT_CONNECT
                   || res == CURLE_OPERATION_TIMEDOUT) {
            // These failures are common behind a captive portal that
            // intercepts DNS, drops connections, or times out.
            isCaptive = YES;
        }

        if (resp.location) {
            free(resp.location);
        }
        if (resp.body) {
            free(resp.body);
        }
        curl_easy_cleanup(curl);

        if (isCaptive && redirectURL) {
            [self performSelectorOnMainThread:@selector(_callCompletionOnMainThread:)
                                   withObject:@[redirectURL, completion]
                                waitUntilDone:NO];
        } else {
            [self performSelectorOnMainThread:@selector(_callCompletionOnMainThread:)
                                   withObject:@[[NSNull null], completion]
                                waitUntilDone:NO];
        }

        __sync_lock_release(&_captivePortalCheckPending);
    }
}

+ (void)_callCompletionOnMainThread:(NSArray *)args
{
    id urlOrNull = [args objectAtIndex:0];
    void (^completion)(BOOL, NSString *) = [args objectAtIndex:1];

    NSString *redirectURL = ([urlOrNull isKindOfClass:[NSString class]]) ? urlOrNull : nil;
    completion(redirectURL != nil, redirectURL);
}

@end
