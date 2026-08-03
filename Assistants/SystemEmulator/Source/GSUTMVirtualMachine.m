#import "GSUTMVirtualMachine.h"

NSString *const GSUTMStateDidChangeNotification = @"GSUTMStateDidChangeNotification";
NSString *const GSUTMConsoleOutputNotification = @"GSUTMConsoleOutputNotification";
NSString *const GSUTMConsoleOutputDataKey = @"GSUTMConsoleOutputDataKey";

@interface GSUTMVirtualMachine ()
@property (nonatomic, strong, readwrite) GSUTMConfiguration *configuration;
@property (nonatomic, readwrite) GSUTMMachineState state;
@property (nonatomic, strong, readwrite) NSTask *task;
@property (nonatomic, readwrite) pid_t qemuPID;
@property (nonatomic, strong) NSPipe *stdoutPipe;
@property (nonatomic, strong) NSPipe *stderrPipe;
@property (nonatomic, strong) NSPipe *stdinPipe;
@property (nonatomic, strong) NSFileHandle *stdoutReadHandle;
@property (nonatomic, strong) NSFileHandle *stderrReadHandle;
@end

@implementation GSUTMVirtualMachine

- (instancetype)initWithConfiguration:(GSUTMConfiguration *)config
{
    self = [super init];
    if (self) {
        _configuration = config;
        _state = GSUTMMachineStateStopped;
    }
    return self;
}

- (void)setState:(GSUTMMachineState)newState
{
    if (_state != newState) {
        _state = newState;
        if (_onStateChange) {
            _onStateChange(newState);
        }
        [[NSNotificationCenter defaultCenter]
         postNotificationName:GSUTMStateDidChangeNotification
         object:self];
    }
}

- (void)stdoutAvailable:(NSNotification *)note
{
    NSData *data = [[note userInfo] objectForKey:NSFileHandleNotificationDataItem];
    if ([data length] > 0) {
        NSString *str = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (str) NSLog(@"QEMU: %@", str);
        if (_onConsoleOutput) _onConsoleOutput(data);
        [[NSNotificationCenter defaultCenter]
         postNotificationName:GSUTMConsoleOutputNotification
         object:self
         userInfo:@{GSUTMConsoleOutputDataKey: data}];
    }
    if (_task && [_task isRunning]) {
        [_stdoutReadHandle readInBackgroundAndNotify];
    }
}

- (void)stderrAvailable:(NSNotification *)note
{
    NSData *data = [[note userInfo] objectForKey:NSFileHandleNotificationDataItem];
    if ([data length] > 0) {
        NSString *str = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (str) NSLog(@"QEMU: %@", str);
        if (_onConsoleOutput) _onConsoleOutput(data);
        [[NSNotificationCenter defaultCenter]
         postNotificationName:GSUTMConsoleOutputNotification
         object:self
         userInfo:@{GSUTMConsoleOutputDataKey: data}];
    }
    if (_task && [_task isRunning]) {
        [_stderrReadHandle readInBackgroundAndNotify];
    }
}

- (BOOL)startWithError:(NSError **)error
{
    if (_state != GSUTMMachineStateStopped) {
        if (error) *error = [NSError errorWithDomain:GSUTMErrorDomain
                                                code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"VM is not stopped"}];
        return NO;
    }

    self.state = GSUTMMachineStateStarting;

    NSString *binary = [_configuration qemuBinary];
    NSArray *args = [_configuration qemuArguments];

    /* Format with quoting for display */
    NSMutableArray *quoted = [NSMutableArray array];
    [quoted addObject:binary];
    for (NSString *arg in args) {
        if ([arg rangeOfString:@" "].location != NSNotFound || [arg length] == 0)
            [quoted addObject:[NSString stringWithFormat:@"'%@'", arg]];
        else
            [quoted addObject:arg];
    }
    NSLog(@"Starting QEMU: %@", [quoted componentsJoinedByString:@" "]);

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:binary];
    [task setArguments:args];
    [task setCurrentDirectoryPath:NSHomeDirectory()];

    _stdoutPipe = [NSPipe pipe];
    _stderrPipe = [NSPipe pipe];
    _stdinPipe = [NSPipe pipe];

    [task setStandardOutput:_stdoutPipe];
    [task setStandardError:_stderrPipe];
    [task setStandardInput:_stdinPipe];

    _stdoutReadHandle = [_stdoutPipe fileHandleForReading];
    _stderrReadHandle = [_stderrPipe fileHandleForReading];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(stdoutAvailable:)
               name:NSFileHandleReadCompletionNotification
             object:_stdoutReadHandle];
    [nc addObserver:self
           selector:@selector(stderrAvailable:)
               name:NSFileHandleReadCompletionNotification
             object:_stderrReadHandle];
    [nc addObserver:self
           selector:@selector(taskDidTerminate:)
               name:NSTaskDidTerminateNotification
             object:task];

    @try {
        [task launch];
    } @catch (NSException *e) {
        if (error) *error = [NSError errorWithDomain:GSUTMErrorDomain
                                                code:-3
                                            userInfo:@{NSLocalizedDescriptionKey: e.reason}];
        self.state = GSUTMMachineStateError;
        return NO;
    }

    _task = task;
    _qemuPID = [task processIdentifier];

    /* Check for early termination (startup error like file lock) */
    [NSThread sleepForTimeInterval:0.3];
    if (![task isRunning]) {
        NSData *errData = [[_stderrPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errMsg = [[[NSString alloc] initWithData:errData
                                                  encoding:NSUTF8StringEncoding] autorelease];
        if (error) *error = [NSError errorWithDomain:GSUTMErrorDomain
                                                code:-4
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                       errMsg ?: @"QEMU exited immediately"}];
        self.state = GSUTMMachineStateError;
        return NO;
    }

    [_stdoutReadHandle readInBackgroundAndNotify];
    [_stderrReadHandle readInBackgroundAndNotify];

    if (_qemuPID > 0) {
        self.state = GSUTMMachineStateStarted;
        NSLog(@"QEMU started with PID %d", _qemuPID);
    }

    return YES;
}

- (void)stop
{
    if (_state == GSUTMMachineStateStopped || _state == GSUTMMachineStateStopping) return;
    self.state = GSUTMMachineStateStopping;
    if (_task && [_task isRunning]) {
        [_task terminate];
    }
}

- (void)taskDidTerminate:(NSNotification *)note
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:NSFileHandleReadCompletionNotification object:_stdoutReadHandle];
    [nc removeObserver:self name:NSFileHandleReadCompletionNotification object:_stderrReadHandle];
    [nc removeObserver:self name:NSTaskDidTerminateNotification object:_task];

    _qemuPID = 0;
    _task = nil;
    _stdoutPipe = nil;
    _stderrPipe = nil;
    _stdinPipe = nil;
    _stdoutReadHandle = nil;
    _stderrReadHandle = nil;

    self.state = GSUTMMachineStateStopped;
}

- (void)sendConsoleInput:(NSData *)data
{
    if (_stdinPipe) {
        [[_stdinPipe fileHandleForWriting] writeData:data];
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_task && [_task isRunning]) {
        [_task terminate];
    }
    [super dealloc];
}

@end
