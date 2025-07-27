// Copyright (c) 2025, Simon Peter
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#ifndef _LOGINWINDOW_PAM_H_
#define _LOGINWINDOW_PAM_H_

#import <Foundation/Foundation.h>
#include <security/pam_appl.h>

@interface LoginWindowPAM : NSObject
{
    pam_handle_t *pam_handle;
    struct pam_conv pam_conversation;
    NSString *_storedUsername;
    NSString *_storedPassword;
    BOOL authenticationInProgress;
}

@property (readonly) NSString *storedUsername;
@property (readonly) NSString *storedPassword;

- (id)init;
- (void)dealloc;
- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password;
- (BOOL)openSessionForUser:(NSString *)username;
- (BOOL)openSession;
- (void)closeSession;
- (char **)getEnvironmentList;

@end

// C function for PAM conversation callback
int loginwindow_pam_conv(int num_msg, const struct pam_message **msg,
                        struct pam_response **resp, void *appdata_ptr);

#endif /* _LOGINWINDOW_PAM_H_ */
