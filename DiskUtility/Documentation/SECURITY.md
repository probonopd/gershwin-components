# SECURITY.md

The privilege model of DiskUtility. Background: ARCHITECTURE.md sections
26-29 and 80.

## 1. Privilege Model

- The GUI process always runs unprivileged. The application is never
  launched as root by design; nothing in the code requests it.
- `DUAuthorizationManager` (Sources/Services/DUAuthorizationManager.m) is
  the only escalation path:
  - When the effective uid is already 0 (`+elevated`, `geteuid() == 0`),
    tools run directly.
  - Otherwise every privileged invocation is rewritten to
    `sudo -A <tool> <args...>`. `sudo -A` collects credentials through the
    askpass helper named by `$SUDO_ASKPASS` - the only sudo mode that can
    work from a GUI process, which owns no terminal for an interactive
    prompt.
  - If no askpass helper is configured or sudo refuses authentication, the
    operation fails with a `DUErrorPermissionDenied` error. Authentication
    failures are recognized from sudo's known output patterns ("password",
    "not allowed", "authentication", "a terminal is required", "askpass")
    plus its credential-failure exit status, so genuine tool failures are
    not misread as auth errors.
- There is no interactive prompt, no root shell, and no generic
  `execute(command)` API. Every privileged call names one specific,
  absolute, pre-resolved executable path with its argument list; the
  authorization layer can only wrap or reject, never compose new commands.

## 2. External Program Execution

All external programs run through `DUProcessRunner`
(Sources/Utilities/DUProcessRunner.{h,m}). Its contract:

- Direct launch, never a shell: no `system()`, no string concatenation into
  a command line, so user input can never gain shell semantics.
- Arguments are passed as `NSArray<NSString *>`.
- Executables are located by `+executablePathForName:` against a fixed
  directory list (`/usr/sbin`, `/sbin`, `/usr/bin`, `/bin`,
  `/usr/local/sbin`, `/usr/local/bin`, `/usr/pkg/sbin`, `/usr/pkg/bin`) -
  never `$PATH`, so a caller-controlled PATH cannot redirect privileged
  operations.
- Both output streams are captured concurrently, so a full pipe cannot
  deadlock either side.
- The synchronous variants accept a timeout; on timeout the child is
  terminated.
- The streaming variant delivers stdout line-by-line (with stderr merged in
  arrival order, since dd/mkfs/fsck report progress on stderr) and returns
  a `DUProcessHandle` whose idempotent, thread-safe `-cancel` terminates
  the child.

## 3. Destructive Operations

- Erase, partition, restore, and repair flows consult the
  `DUConfirmDestructiveOperations` preference before touching anything
  (Sources/Controllers/DUFirstAidViewController.m, DUEraseViewController.m,
  DUPartitionViewController.m, DURestoreViewController.m). It defaults to
  YES and is registered in `DUPreferencesController registerDefaults`;
  storage operations never get silent defaults.
- Image creation refuses to clobber: destinations are opened with
  `O_EXCL`/existence checks and partial outputs are removed on any failure,
  cancellation, or verification mismatch.

## 4. Concurrent Operation Safety

- `DUOperationManager startOperation:error:` enforces per-device locks:
  an operation whose `primaryObject.identifier` matches an active
  operation (Preparing/Running/Cancelling all count) is rejected with
  `DUErrorDeviceBusy`. Operations on different devices run concurrently;
  objectless image operations cannot conflict.
- Finished operations move to a bounded history (20 entries).

## 5. Data Handling

- Backend and tool output is treated as untrusted data: parsers skip
  unrecognized lines, empty tokens are dropped, error details carry at most
  an 800-character tail of tool output under `kDUBackendDetailKey`, and
  full transcripts go to the user-visible operation log instead of error
  dictionaries.
- Privileged operations are logged to the operation log; privileged reads
  surface sudo failures explicitly rather than reporting silently short
  data.
