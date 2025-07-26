#import "LoginWindowPAM.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// C function for PAM conversation callback
int loginwindow_pam_conv(int num_msg, const struct pam_message **msg,
                        struct pam_response **resp, void *appdata_ptr)
{
    NSLog(@"[PAM] Conversation callback invoked with %d messages", num_msg);
    LoginWindowPAM *pamObj = (__bridge LoginWindowPAM *)appdata_ptr;
    *resp = (struct pam_response *)calloc(num_msg, sizeof(struct pam_response));
    
    if (!*resp) {
        NSLog(@"[PAM] calloc failed for pam_response");
        return PAM_BUF_ERR;
    }
    
    int result = PAM_SUCCESS;
    
    for (int i = 0; i < num_msg; i++) {
        (*resp)[i].resp = NULL;
        (*resp)[i].resp_retcode = 0;
        NSLog(@"[PAM] Message %d: style=%d, msg='%s'", i, msg[i]->msg_style, msg[i]->msg);
        switch (msg[i]->msg_style) {
            case PAM_PROMPT_ECHO_ON:
                NSLog(@"[PAM] Prompt for username");
                if ([pamObj storedUsername]) {
                    (*resp)[i].resp = strdup([[pamObj storedUsername] UTF8String]);
                    NSLog(@"[PAM] Responded with username: %@", [pamObj storedUsername]);
                } else {
                    NSLog(@"[PAM] No username stored");
                }
                break;
            case PAM_PROMPT_ECHO_OFF:
                NSLog(@"[PAM] Prompt for password");
                if ([pamObj storedPassword]) {
                    (*resp)[i].resp = strdup([[pamObj storedPassword] UTF8String]);
                    NSLog(@"[PAM] Responded with password (hidden)");
                } else {
                    NSLog(@"[PAM] No password stored");
                }
                break;
            case PAM_ERROR_MSG:
            case PAM_TEXT_INFO:
                NSLog(@"[PAM] Info/Error: %s", msg[i]->msg);
                break;
            default:
                NSLog(@"[PAM] Unknown message style: %d", msg[i]->msg_style);
                result = PAM_CONV_ERR;
                break;
        }
        if (result != PAM_SUCCESS) {
            NSLog(@"[PAM] Conversation error at message %d", i);
            break;
        }
    }
    if (result != PAM_SUCCESS) {
        for (int i = 0; i < num_msg; i++) {
            if ((*resp)[i].resp) {
                free((*resp)[i].resp);
                (*resp)[i].resp = NULL;
            }
        }
        free(*resp);
        *resp = NULL;
        NSLog(@"[PAM] Conversation failed, responses freed");
    }
    return result;
}

@implementation LoginWindowPAM

@synthesize storedUsername = _storedUsername;
@synthesize storedPassword = _storedPassword;

- (id)init
{
    self = [super init];
    if (self) {
        pam_handle = NULL;
        pam_conversation.conv = loginwindow_pam_conv;
        pam_conversation.appdata_ptr = (__bridge void *)self;
        _storedUsername = nil;
        _storedPassword = nil;
        authenticationInProgress = NO;
        NSLog(@"[PAM] LoginWindowPAM initialized");
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"[PAM] Dealloc called");
    if (pam_handle) {
        pam_end(pam_handle, PAM_SUCCESS);
        pam_handle = NULL;
        NSLog(@"[PAM] pam_end called in dealloc");
    }
    [_storedUsername release];
    [_storedPassword release];
    [super dealloc];
}

- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password
{
    NSLog(@"[PAM] Starting authentication for user: %@", username);
    if (authenticationInProgress) {
        NSLog(@"[PAM] Authentication already in progress");
        return NO;
    }
    authenticationInProgress = YES;
    [_storedUsername release];
    [_storedPassword release];
    _storedUsername = [username copy];
    _storedPassword = [password copy];
    NSLog(@"[PAM] Credentials stored: username=%@ password=%@", _storedUsername, _storedPassword ? @"(hidden)" : @"(nil)");
    // "system" is the service name used for PAM authentication, there is a file in /etc/pam.d/ that defines the service
    int result = pam_start("system", [username UTF8String], &pam_conversation, &pam_handle);
    NSLog(@"[PAM] pam_start result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        NSLog(@"[PAM] pam_start failed: %s", pam_strerror(pam_handle, result));
        authenticationInProgress = NO;
        return NO;
    }
    result = pam_set_item(pam_handle, PAM_TTY, ttyname(STDIN_FILENO));
    NSLog(@"[PAM] pam_set_item PAM_TTY result: %d (%s)", result, pam_strerror(pam_handle, result));
    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) == 0) {
        pam_set_item(pam_handle, PAM_RHOST, hostname);
        NSLog(@"[PAM] pam_set_item PAM_RHOST: %s", hostname);
    } else {
        NSLog(@"[PAM] gethostname failed");
    }
    result = pam_authenticate(pam_handle, 0);
    NSLog(@"[PAM] pam_authenticate result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        NSLog(@"[PAM] pam_authenticate failed: %s", pam_strerror(pam_handle, result));
        pam_end(pam_handle, result);
        pam_handle = NULL;
        authenticationInProgress = NO;
        [_storedPassword release];
        _storedPassword = nil;
        return NO;
    }
    result = pam_acct_mgmt(pam_handle, PAM_SILENT);
    NSLog(@"[PAM] pam_acct_mgmt result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        NSLog(@"[PAM] pam_acct_mgmt failed: %s", pam_strerror(pam_handle, result));
        pam_end(pam_handle, result);
        pam_handle = NULL;
        authenticationInProgress = NO;
        [_storedPassword release];
        _storedPassword = nil;
        return NO;
    }
    authenticationInProgress = NO;
    [_storedPassword release];
    _storedPassword = nil;
    NSLog(@"[PAM] Authentication succeeded for user: %@", username);
    return YES;
}

- (BOOL)openSession
{
    NSLog(@"[PAM] openSession called");
    if (!pam_handle) {
        NSLog(@"[PAM] openSession failed: pam_handle is NULL");
        return NO;
    }
    int result = pam_setcred(pam_handle, PAM_ESTABLISH_CRED);
    NSLog(@"[PAM] pam_setcred result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        NSLog(@"[PAM] pam_setcred failed: %s", pam_strerror(pam_handle, result));
        return NO;
    }
    result = pam_open_session(pam_handle, 0);
    NSLog(@"[PAM] pam_open_session result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        NSLog(@"[PAM] pam_open_session failed: %s", pam_strerror(pam_handle, result));
        pam_setcred(pam_handle, PAM_DELETE_CRED);
        return NO;
    }
    NSLog(@"[PAM] Session opened successfully");
    return YES;
}

- (void)closeSession
{
    NSLog(@"[PAM] closeSession called");
    if (!pam_handle) {
        NSLog(@"[PAM] closeSession: pam_handle is NULL");
        return;
    }
    int result = pam_close_session(pam_handle, 0);
    NSLog(@"[PAM] pam_close_session result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        NSLog(@"[PAM] pam_close_session failed: %s", pam_strerror(pam_handle, result));
    }
    result = pam_setcred(pam_handle, PAM_DELETE_CRED);
    NSLog(@"[PAM] pam_setcred (delete) result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        NSLog(@"[PAM] pam_setcred (delete) failed: %s", pam_strerror(pam_handle, result));
    }
    pam_end(pam_handle, PAM_SUCCESS);
    pam_handle = NULL;
    NSLog(@"[PAM] PAM transaction ended");
}

- (char **)getEnvironmentList
{
    NSLog(@"[PAM] getEnvironmentList called");
    if (!pam_handle) {
        NSLog(@"[PAM] getEnvironmentList: pam_handle is NULL");
        return NULL;
    }
    return pam_getenvlist(pam_handle);
}

@end
