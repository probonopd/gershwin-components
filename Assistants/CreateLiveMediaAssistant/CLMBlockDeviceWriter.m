#import "CLMBlockDeviceWriter.h"
#import <errno.h>
#import <string.h>

@implementation CLMBlockDeviceWriter
{
    NSTask *_task;
    NSFileHandle *_writeHandle;
    int64_t _bytesWritten;
    NSString *_devicePath;
    NSString *_helperPath;
}

@synthesize devicePath = _devicePath;
@synthesize bytesWritten = _bytesWritten;

- (instancetype)initWithDevicePath:(NSString *)devicePath
{
    self = [super init];
    if (self) {
        _devicePath = [devicePath copy];
        _bytesWritten = 0;
        _helperPath = nil;
    }
    return self;
}

- (void)dealloc
{
    if (_task) {
        [_task terminate];
        _task = nil;
    }
}

- (BOOL)isOpen
{
    return _task != nil && _writeHandle != nil;
}

- (BOOL)openWithError:(NSError **)error
{
    if (_task) return YES;

    if (!_helperPath) {
        _helperPath = [[NSBundle mainBundle] pathForResource:@"clm-helper" ofType:nil];
    }
    if (!_helperPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"CLMBlockDeviceWriter"
                                        code:-1
                                    userInfo:@{
                NSLocalizedDescriptionKey: NSLocalizedString(@"Could not find clm-helper tool", @"")
            }];
        }
        return NO;
    }

    _task = [[NSTask alloc] init];
    [_task setLaunchPath:@"/usr/bin/sudo"];
    [_task setArguments:@[@"-A", @"-E", _helperPath, @"write", _devicePath]];

    NSPipe *inPipe = [NSPipe pipe];
    [_task setStandardInput:inPipe];
    _writeHandle = [inPipe fileHandleForWriting];

    NSDebugLLog(@"gwcomp", @"CLMBlockDeviceWriter: launching sudo clm-helper write %@", _devicePath);

    @try {
        [_task launch];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"CLMBlockDeviceWriter"
                                        code:-1
                                    userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    NSLocalizedString(@"Failed to launch clm-helper: %@", @""),
                    [exception reason]]
            }];
        }
        _task = nil;
        _writeHandle = nil;
        return NO;
    }

    return YES;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error
{
    return [self writeBytes:[data bytes] length:[data length] error:error];
}

- (BOOL)writeBytes:(const void *)bytes length:(size_t)length error:(NSError **)error
{
    if (!_writeHandle) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                        code:EBADF
                                    userInfo:@{
                NSLocalizedDescriptionKey: NSLocalizedString(@"Device not open", @"")
            }];
        }
        return NO;
    }

    NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];
    @try {
        [_writeHandle writeData:data];
        _bytesWritten += length;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"CLMBlockDeviceWriter"
                                        code:-1
                                    userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    NSLocalizedString(@"Write error on %@: %@", @""),
                    _devicePath, [exception reason]]
            }];
        }
        return NO;
    }

    return YES;
}

- (BOOL)synchronizeWithError:(NSError **)error
{
    (void)error;
    return YES;
}

- (BOOL)closeWithError:(NSError **)error
{
    if (!_task) return YES;

    @try {
        [_writeHandle closeFile];
        _writeHandle = nil;
        [_task waitUntilExit];
        int status = [_task terminationStatus];
        if (status != 0) {
            if (error) {
                *error = [NSError errorWithDomain:@"CLMBlockDeviceWriter"
                                            code:status
                                        userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        NSLocalizedString(@"clm-helper exited with status %d", @""), status]
                }];
            }
            _task = nil;
            return NO;
        }
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"CLMBlockDeviceWriter"
                                        code:-1
                                    userInfo:@{
                NSLocalizedDescriptionKey: [exception reason]
            }];
        }
        _task = nil;
        return NO;
    }

    _task = nil;
    return YES;
}

@end
