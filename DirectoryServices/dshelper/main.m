#import <Foundation/Foundation.h>
#import "dshelper.h"
#import <signal.h>
#import <unistd.h>

static DSHelper *helper = nil;

void signalHandler(int sig) {
    NSLog(@"dshelper: Received signal %d, shutting down...", sig);
    [helper unregisterService];
    [helper stopServer];
    unlink("/var/run/dshelper.pid");
    exit(0);
}

void printUsage(const char *progname) {
    fprintf(stderr, "Usage: %s [-d] [-h]\n", progname);
    fprintf(stderr, "  -d    Run in foreground (debug mode)\n");
    fprintf(stderr, "  -h    Show this help\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Directory Services Helper - provides user/group lookups for NSS\n");
    fprintf(stderr, "Listens on: %s\n", DS_SOCKET_PATH);
    fprintf(stderr, "Checks: %s (first)\n", [DS_NETWORK_USERS_PLIST UTF8String]);
    fprintf(stderr, "        %s (fallback)\n", [DS_LOCAL_USERS_PLIST UTF8String]);
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
            fprintf(stderr, "dshelper: Must run as root\n");
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
                printf("dshelper: Started with PID %d\n", pid);
                return 0;
            }

            // Child continues
            setsid();
            chdir("/");

            // Write pid file
            FILE *pf = fopen("/var/run/dshelper.pid", "w");
            if (pf) {
                fprintf(pf, "%d\n", getpid());
                fclose(pf);
            }

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
                NSLog(@"dshelper: Failed to create %@: %@", dirPath, error);
            }
        }

        // Start server
        helper = [DSHelper sharedHelper];

        NSLog(@"dshelper: Starting Directory Services Helper");

        // Register with port name server for discovery BEFORE starting
        // the blocking accept loop (servers only)
        [helper registerService];

        if (![helper startServer]) {
            NSLog(@"dshelper: Failed to start server");
            return 1;
        }

        return 0;
    }
}
