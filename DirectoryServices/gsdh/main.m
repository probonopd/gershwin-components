#import <Foundation/Foundation.h>
#import "gsdh.h"
#import <signal.h>
#import <unistd.h>

static GSDirectoryHelper *helper = nil;

void signalHandler(int sig) {
    NSLog(@"gsdh: Received signal %d, shutting down...", sig);
    [helper stopServer];
    exit(0);
}

void printUsage(const char *progname) {
    fprintf(stderr, "Usage: %s [-d] [-h]\n", progname);
    fprintf(stderr, "  -d    Run in foreground (debug mode)\n");
    fprintf(stderr, "  -h    Show this help\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "GNUstep Directory Helper - provides user/group lookups for NSS/PAM\n");
    fprintf(stderr, "Listens on: %s\n", GSDH_SOCKET_PATH);
    fprintf(stderr, "Reads from: %s\n", [GSDH_USERS_PLIST UTF8String]);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL foreground = NO;
        int opt;

        while ((opt = getopt(argc, argv, "dh")) != -1) {
            switch (opt) {
                case 'd':
                    foreground = YES;
                    break;
                case 'h':
                    printUsage(argv[0]);
                    return 0;
                default:
                    printUsage(argv[0]);
                    return 1;
            }
        }

        // Must run as root to read password hashes
        if (getuid() != 0) {
            fprintf(stderr, "gsdh: Must run as root\n");
            return 1;
        }

        // Daemonize unless -d flag
        if (!foreground) {
            pid_t pid = fork();
            if (pid < 0) {
                perror("fork");
                return 1;
            }
            if (pid > 0) {
                // Parent exits
                printf("gsdh: Started with PID %d\n", pid);
                return 0;
            }

            // Child continues
            setsid();
            chdir("/");

            // Close standard file descriptors
            close(STDIN_FILENO);
            close(STDOUT_FILENO);
            close(STDERR_FILENO);
        }

        // Set up signal handlers
        signal(SIGINT, signalHandler);
        signal(SIGTERM, signalHandler);
        signal(SIGPIPE, SIG_IGN);

        // Create directory if needed
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dirPath = @"/Local/Library/DirectoryServices";
        if (![fm fileExistsAtPath:dirPath]) {
            NSError *error = nil;
            [fm createDirectoryAtPath:dirPath
          withIntermediateDirectories:YES
                           attributes:@{
                               NSFilePosixPermissions: @0755,
                               NSFileOwnerAccountID: @0,
                               NSFileGroupOwnerAccountID: @0
                           }
                                error:&error];
            if (error) {
                NSLog(@"gsdh: Failed to create %@: %@", dirPath, error);
            }
        }

        // Start server
        helper = [GSDirectoryHelper sharedHelper];

        NSLog(@"gsdh: Starting GNUstep Directory Helper");

        if (![helper startServer]) {
            NSLog(@"gsdh: Failed to start server");
            return 1;
        }

        return 0;
    }
}
