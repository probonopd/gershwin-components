#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static int helperUmount(NSString *device)
{
    NSTask *ls = [[NSTask alloc] init];
    [ls setLaunchPath:@"/bin/sh"];
    [ls setArguments:@[@"-c", [NSString stringWithFormat:@"ls /dev/%@* 2>/dev/null || true", device]]];
    NSPipe *out = [NSPipe pipe];
    [ls setStandardOutput:out];
    [ls launch];
    [ls waitUntilExit];

    NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *parts = [output componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    for (NSString *part in parts) {
        if ([part length] == 0) continue;
        NSTask *um = [[NSTask alloc] init];
        [um setLaunchPath:@"/sbin/umount"];
        [um setArguments:@[part]];
        @try {
            [um launch];
            [um waitUntilExit];
        } @catch (NSException *e) {
            fprintf(stderr, "umount %s failed: %s\n", [part UTF8String], [[e reason] UTF8String]);
        }
    }
    return 0;
}

static int helperWrite(NSString *device)
{
    const char *path = [device UTF8String];
    int fd = open(path, O_WRONLY | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 1;
    }

    char buf[65536];
    ssize_t n;
    while ((n = read(STDIN_FILENO, buf, sizeof(buf))) > 0) {
        const char *ptr = buf;
        ssize_t remaining = n;
        while (remaining > 0) {
            ssize_t written = write(fd, ptr, remaining);
            if (written < 0) {
                if (errno == EINTR) continue;
                fprintf(stderr, "write %s: %s\n", path, strerror(errno));
                close(fd);
                return 1;
            }
            ptr += written;
            remaining -= written;
        }
    }

    if (fsync(fd) < 0) {
        fprintf(stderr, "fsync %s: %s\n", path, strerror(errno));
    }
    close(fd);
    return 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: clm-helper unmount <device>\n");
            fprintf(stderr, "       clm-helper write <device>\n");
            return 1;
        }

        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"unmount"]) {
            if (argc < 3) { fprintf(stderr, "unmount: missing device\n"); return 1; }
            return helperUmount([NSString stringWithUTF8String:argv[2]]);
        } else if ([cmd isEqualToString:@"write"]) {
            if (argc < 3) { fprintf(stderr, "write: missing device\n"); return 1; }
            return helperWrite([NSString stringWithUTF8String:argv[2]]);
        } else {
            fprintf(stderr, "unknown command: %s\n", [cmd UTF8String]);
            return 1;
        }
    }
}
